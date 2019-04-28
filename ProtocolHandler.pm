package Plugins::RadioParadise::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use JSON::XS::VersionOneAndTwo;
use Tie::Cache::LRU;
use POSIX qw(ceil);

use Slim::Networking::SimpleAsyncHTTP;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use constant BASE_URL => 'https://api.radioparadise.com/api/get_block?bitrate=%s&chan=%s&info=true%s';

# skip very short segments, like eg. some announcements, they seem to cause timing or buffering issues
use constant MIN_EVENT_LENGTH => 15;

my $prefs = preferences('plugin.radioparadise');
tie my %blockData, 'Tie::Cache::LRU', 16;

my %AAC_BITRATE = (
	0 => 32,
	1 => 64,
	2 => 128,
	3 => 320,
);

my $log = logger('plugin.radioparadise');

# To support remote streaming (synced players, slimp3/SB1), we need to subclass Protocols::HTTP
sub new {
	my $class  = shift;
	my $args   = shift;

	my $client = $args->{client};

	my $song      = $args->{'song'};
	my $streamUrl = $song->streamUrl() || return;

	my ($quality, $format) = _getStreamParams( $args->{url} );

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $args->{'song'},
		client  => $client,
		bitrate => $quality < 4 ? $AAC_BITRATE{$quality} * 1024 : 850_000,
	} ) || return;

	${*$sock}{contentType} = 'audio/' . $format;

	return $sock;
}

sub getFormatForURL {
	my ($class, $url) = @_;

	my (undef, $format) = _getStreamParams( $url );
	return $format;
}

# sub formatOverride {
# 	my ($class, $song) = @_;
# 	my $format = $class->getFormatForURL($song->currentTrack()->url);

# 	return 'aac' if $format eq 'mp4';
# 	return 'flc' if $format eq 'flac';

# 	return $format;
# }

sub canSeek { 0 }

# allow players that can handle HTTPS to decide
sub canDirectStream { 
	my $class = shift;
	my $client = shift;
	my $url = shift;
	return $class->SUPER::canDirectStream($client, $client->streamingSong->streamUrl, @_);
}

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


sub isRepeatingStream { 1 }

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

	my ($quality, $format, $mix) = _getStreamParams($song->track()->url);

	my $url = sprintf(BASE_URL, $quality, $mix, $event);
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

		$song->streamUrl($result->{url});
	}

	main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($result));

	$http->params('cb')->();
}

# we ignore most of this... only return a fake bitrate, and the content type. Length would create a progress bar
sub parseDirectHeaders {
	my $class   = shift;
	my $client  = shift || return;
	my $url     = shift;
	my @headers = @_;

	my $bitrate = 850_000;
	$client = $client->master;

	my ($length, $ct);

	foreach my $header (@headers) {
		if ( $header =~ /^Content-Length:\s*(.*)/i ) {
			$length = $1;
		}
		elsif ( $header =~ /^Content-Type:\s*(\S*)/i ) {
			$ct = $1;
		}
	}

	my $song = $client->streamingSong();
	$ct =~ s/(?:m4a|mp4)/aac/i;
	$ct = Slim::Music::Info::mimeToType($ct);

	if ($ct =~ /aac/i) {
		my ($quality, $format) = _getStreamParams($song->track->url);
		$bitrate = $AAC_BITRATE{$quality} * 1024;
	}
	elsif ($length && $class->getBlockData($song)) {
		$bitrate = $length * 8 / $class->getBlockData($song)->{length};
	}
	
	#       title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, $ct, $length, undef);
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
			my ($quality, $format) = _getStreamParams($song->track()->url);
			my $bitrate = '';

			if ($quality == 4 || $format eq 'flac') {
				$bitrate = int($song->bitrate ? ($song->bitrate / 1024) : 850) . 'k VBR FLAC';
			}
			elsif ($quality < 4) {
				$bitrate = $AAC_BITRATE{$quality} . 'k CBR AAC';
			}

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
	return $url;
}

sub getIcon {
	return Plugins::RadioParadise::Plugin->_pluginDataFor('icon');
}

sub _getStreamParams {
	if ( $_[0] =~ m{radioparadise://(.+?)-?(\d)?\.(m4a|aac|mp4|flac)}i ) {
		my $quality = $1;
		my $mix = $2 || 0;
		my $format = lc($3);

		$format = 'mp4' if $format =~ /m4a|aac/;
		$quality = 4 if $format eq 'flac';

		return ($quality, $format, $mix);
	}
}

1;