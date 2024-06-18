package Plugins::RadioParadise::ProtocolHandler;

use strict;
use base qw(IO::Handle);

use JSON::XS::VersionOneAndTwo;
use Tie::Cache::LRU;
use POSIX qw(ceil);
use List::Util qw(min max);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Utils::Errno;

use Plugins::RadioParadise::Stations;

use constant BASE_URL => 'https://api.radioparadise.com/api/get_block?bitrate=4&chan=%s&info=true%s';
use constant MAX_ERRORS	=> 5;

use constant DISCONNECTED => 0;
use constant IDLE         => 1;
use constant CONNECTING   => 2;
use constant CONNECTED    => 3;

my $prefs = preferences('plugin.radioparadise');
my $log = logger('plugin.radioparadise');

tie my %blockData, 'Tie::Cache::LRU', 16;

sub new {
	my $class  = shift;
	my $args   = shift;
	my $song = $args->{'song'};

	my $streamUrl = $song->streamUrl || return;
	my $sock = $class->SUPER::new;

	${*$sock}{'vars'} = {       # variables which hold state for this instance:
		'url'     => $streamUrl, # Url to grab
		'song'    => $song,      # song object
		'status'  => IDLE,       # streaming in progress
		'offset'  => 0,          # number of bytes received
		'errors'  => 0,          # max number of consecutives errors before giving up
		'session' => Slim::Networking::Async::HTTP->new,
	};

	return $sock;
}

sub close {
	my $self = shift;
	my $v = ${*$self}{'vars'};
	$v->{'session'}->disconnect unless $v->{'status'} == DISCONNECTED;
	$v->{'status'} = DISCONNECTED;
	$v->{'offset'} = 0;
	$self->SUPER::close();
}

sub sysread {
	my $self  = $_[0];
	# return in $_[1]
	my $maxBytes = $_[2];
	my $v = ${*$self}{'vars'};

	return 0 if $v->{'status'} == DISCONNECTED;

	# need to start streaming
	if ( $v->{'status'} == IDLE ) {
		my $request = HTTP::Request->new( GET => $v->{'url'} );
		$request->header( 'Range', "bytes=$v->{'offset'}-" );
		$v->{'status'} = CONNECTING;
		$v->{'lastSeen'} = undef;

		main::DEBUGLOG && $log->is_debug && $log->debug("streaming from $v->{'offset'} for $v->{'url'}");

		$v->{'session'}->send_request( {
			request     => $request,
			onHeaders => sub {
				$v->{'length'} = shift->response->headers->header('Content-Length');
				$v->{'length'} += $v->{'offset'} if $v->{'length'};
				$v->{'status'} = CONNECTED;
				$v->{'errors'} = 0;
				$v->{'song'}->bitrate($v->{'length'} * 8 / getBlockData(undef, $v->{'song'})->{length}) if $v->{'length'};
				Slim::Control::Request::notifyFromArray( $v->{'song'}->master, [ 'newmetadata' ] );
				main::INFOLOG && $log->is_info && $log->info("length ", $v->{'length'} || 0, " setting bitrate ", int ($v->{'song'}->bitrate), " for $v->{'url'}");
			},
			onError  => sub {
				$v->{'session'}->disconnect;
				$v->{'status'} = IDLE;
				$v->{'errors'}++;
				$log->error("cannot open session for $v->{'url'} $_[1] ");
			},
		} );
	}

	# the child socket should be non-blocking so here we can safely call
	# read_entity_body which calls sysread if buffer is empty. This is normally
	# a LMS callback invoked when select() has something to read on that socket.
	my $bytes = $v->{'session'}->socket->read_entity_body($_[1], $maxBytes) if $v->{'status'} == CONNECTED;

	if ( $bytes && $bytes != -1 ) {
		$v->{'offset'} += $bytes;
		$v->{'lastSeen'} = time();
		return $bytes;
	} elsif ( ($bytes == -1 || !defined $bytes) && $v->{'errors'} < MAX_ERRORS && ($v->{'status'} != CONNECTED || $! == EINTR || $! == EWOULDBLOCK) && (!defined $v->{'lastSeen'} || time() - $v->{'lastSeen'} < 5) ){
		$! = EINTR;
		main::DEBUGLOG && $log->is_debug && $log->debug("need to wait for $v->{'url'}");
		return undef;
	} elsif ( !$v->{'length'} || $v->{'offset'} == $v->{'length'} || $v->{'errors'} >= MAX_ERRORS ) {
		$v->{'session'}->disconnect;
		$v->{'status'} = DISCONNECTED;
		main::INFOLOG && $log->is_info && $log->info("end of $v->{'url'} s:", time() - $v->{'lastSeen'}, " e:$v->{'errors'} c:$!");
		return 0;
	} else {
		$log->warn("unexpected connection close at $v->{'offset'}/$v->{'length'} (since ", time() - $v->{'lastSeen'}, ") for $v->{'url'} $_! ");
		$v->{'session'}->disconnect;
		$v->{'status'} = IDLE;
		$v->{'errors'}++;
		$! = EINTR;
		return undef;
	}
}

sub canSeek { 0 }
sub isRemote { 1 }
sub canDirectStream { 0 }
sub isRepeatingStream { 1 }
sub contentType { 'audio/flac' };

sub canDoAction {
	my ( $class, $client, $url, $action ) = @_;

	# "stop" seems to be called when a user pressed FWD...
	if ( $action eq 'stop' ) {
		my $song = $client->master->streamingSong();
		$song->pluginData( skip => 1 );
	}
	elsif ( $action eq 'pause' || $action eq 'rew' ) {
		return 0;
	}

	return 1;
}

# Avoid scanning
sub scanUrl {
	my ( $class, $url, $args ) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $client = $song->master;
	my $event = '';

	if ( my $blockData = $class->getBlockData($song) ) {
		# on skip we can get the next track
		if ( $song->pluginData('skip') ) {
			$event = '&event=' . $blockData->{event} . '&elapsed=' . $client->songElapsedSeconds;
			$song->pluginData( skip => 0 );
		}
		elsif ( my $endevent = $blockData->{'end_event'} ) {
			$event = '&event=' . $endevent;
		}
	}

	$song->track()->url =~ m{radioparadise://(.+?)-?(\d+)?}i;
	my $url = sprintf(BASE_URL, ($2 || 0), $event);
	main::INFOLOG && $log->info("Fetching new block of events: $url");

	Slim::Networking::SimpleAsyncHTTP->new(
		\&_gotNewTrack,
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			$errorCb->();
		},
		{
			timeout => 15,
			cb => $successCb,
			ecb => $errorCb,
			song => $song,
		},
	)->get($url);
}

sub _gotNewTrack {
	my $http = shift;

	my $result = eval { from_json($http->content) };

	$@ && $log->error($@);

	if ($result && ref $result && $result->{song}) {
		my @songkeys = sort keys %{$result->{song}};
		my $lastsong = $result->{song}->{$songkeys[-1]};

		# add a virtual track for the optional audio commentary (last track) or correct last track duration when rounding error
		my $gap = $result->{length} * 1000 - ($lastsong->{elapsed} + $lastsong->{duration});
		if ($gap) {
			# announcements sometimes come in their own block, with a duration of 0, but length defined
			if (scalar @songkeys == 1 && $lastsong->{duration} == 0) {
				main::INFOLOG && $log->is_info && $log->info("Title duration of a single block track is zero. Set to the block's length.");
				$lastsong->{duration} = $result->{length} * 1000;
			}
			elsif ($gap > 1000) {
				main::INFOLOG && $log->is_info && $log->info("Total duration is longer than sum of tracks. Add empty track item to compensate.");
				$result->{song}->{$songkeys[-1] + 1} = {
					album    => "Commercial-free",
					artist   => "",
					duration => $result->{length} * 1000 - ($lastsong->{elapsed} + $lastsong->{duration}),
					elapsed  => $lastsong->{elapsed} + $lastsong->{duration},
					event    => $lastsong->{event},
					song_id  => 0,
					title    => "Radio Paradise",
				};
			}
			else {
				$lastsong->{duration} += $gap;
			}
		}

		my $song = $http->params('song');
		__PACKAGE__->setBlockData($result);

		# XXX - https
		$result->{url} =~ s/^https/http/;

		$song->streamUrl($result->{url});
	}

	main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($result));

	$http->params('cb')->();
}

sub getMetadataFor {
	my ( $class, $client, $url, $forceCurrent ) = @_;

	$client = $client->master;
	my $song = $forceCurrent ? $client->streamingSong() : $client->playingSong();
	return {} unless $song;

	main::DEBUGLOG && $log->is_debug && $log->debug("Refreshing metadata");

	my $icon = $class->getIcon();
	my $cached = $class->getBlockData($song);

	# want the streaming song and url specific, means we want the whole block
	if ($cached && $forceCurrent eq 'repeating') {
		main::INFOLOG && $log->is_info && $log->info("returning 1st song of new block");

		return {
			icon    => $icon,
			cover   => $icon,
			bitrate => '',
			title   => 'Radio Paradise',
			duration => $cached->{length},
			secs   => $cached->{length},
			song_id => 0,
			slideshow => [],
			buttons   => {
				rew => 0,
			},
		};
	}

	if ($cached) {
		my $timeOffset = $song->seekdata->{timeOffset} if $song->seekdata;
		my $songtime = ($client->songElapsedSeconds + $timeOffset) * 1000;

		main::DEBUGLOG && $log->is_debug && $log->debug(sprintf("Current playtime in block (%s): %.1f (current %s)", $song->streamUrl, $songtime / 1000, $forceCurrent || 0));

		my $songdata;
		my $index;

		foreach (sort keys %{$cached->{song}}) {
			$songdata = $cached->{song}->{$index = $_};
			last if $songtime <= $songdata->{elapsed} + $songdata->{duration};
		}

		my $meta;

		if ($url) {
			my $bitrate = int($song->bitrate ? ($song->bitrate / 1024) : 850) . 'k VBR FLAC';

			if (main::INFOLOG && $log->is_info) {
				$bitrate .=  sprintf(" (%u/%u - %u:%02u)", $index + 1, scalar(keys %{$cached->{song}}), $cached->{length}/60, int($cached->{length} % 60));
			}

			$meta = {
				artist => $songdata->{artist},
				album  => $songdata->{album},
				title  => $songdata->{title},
				year   => $songdata->{year},
				duration => $songdata->{duration} / 1000,
				secs   => $songdata->{duration} / 1000,
				cover  => $song->pluginData('httpCover') || ($songdata->{cover} ? 'https:' . $cached->{image_base} . $songdata->{cover} : $icon),
				bitrate=> $bitrate,
				slideshow => [ split(/,/, ($songdata->{slideshow} || '')) ],
				song_id=> $songdata->{song_id},
				extid  => 'radioparadise:' . $songdata->{song_id},
				buttons   => {
					rew => 0,
				},
			};
		}

		return $meta if $forceCurrent;

		my $remainingTimeInBlock;

		if ($song->pluginData('lastSongId') != $songdata->{song_id}) {
			$remainingTimeInBlock = ($songdata->{elapsed} + $songdata->{duration} - $songtime) / 1000;

			$song->pluginData(lastSongId => $songdata->{song_id});
			$song->duration($songdata->{duration} / 1000);
			$song->startOffset($timeOffset - $songdata->{elapsed} / 1000);
			main::INFOLOG && $log->is_info && $log->info("duration: $songdata->{duration}, startOffset(ms): $songdata->{elapsed}, total(ms): $songtime, track: ", Slim::Player::Source::songTime($client));

			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		} elsif (!$url) {
			$remainingTimeInBlock = ($songdata->{elapsed} + $songdata->{duration} - $songtime) / 1000;
			$remainingTimeInBlock = 1 if $remainingTimeInBlock <= 0;
		}

		if ($remainingTimeInBlock) {
			Slim::Utils::Timers::killTimers($client, \&_metadataUpdate);
			Slim::Utils::Timers::setTimer($client, time() + ceil($remainingTimeInBlock), \&_metadataUpdate);
			main::INFOLOG && $log->is_info && $log->info("Scheduling an update for the end of this song: $remainingTimeInBlock");
		}

		return $meta;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("Returning default metadata");

	return {
		icon    => $icon,
		cover   => $icon,
		bitrate => '',
		title   => 'Radio Paradise',
		duration=> 0,
		secs    => 0,
		song_id => 0,
		slideshow => [],
		buttons   => {
			rew => 0,
		},
	};
}

sub _metadataUpdate {
	my ($client) = @_;
	main::INFOLOG && $log->is_info && $log->info("Running scheduled metadata update");
	__PACKAGE__->getMetadataFor($client);
}

sub getBlockData {
	my ($class, $song) = @_;
	return $blockData{_cleanupBlockURL($song->streamUrl)};
}

sub setBlockData {
	my ($class, $data) = @_;

	return unless $data && ref $data && $data->{url};

	$blockData{_cleanupBlockURL($data->{url})} = $data;
}

sub _cleanupBlockURL {
	my $url = shift || '';
	$url =~ s/\?.*//;

	# XXX - https
	$url =~ s/^http:/https:/;
	return $url;
}

sub getIcon {
	return Plugins::RadioParadise::Plugin->_pluginDataFor('icon');
}

# Optionally override replaygain to use the plugin's gain value
sub trackGain {
	my ( $class, $client, $url ) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("Url: $url");

	my $cPrefs = preferences('server')->client($client);  # access player prefs
	my $rgmode = $cPrefs->get('replayGainMode');  # is player replay gain in effect?

	# if so, return the sum of remoteReplayGain and the plugin's adjustment
	return $rgmode ? $cPrefs->get('remoteReplayGain') + $prefs->get('replayGain') : undef;
}

1;