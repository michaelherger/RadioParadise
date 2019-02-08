package Plugins::RadioParadise::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use JSON::XS::VersionOneAndTwo;

use Slim::Networking::SimpleAsyncHTTP;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use constant BASE_URL => 'https://api.radioparadise.com/api/get_block?bitrate=%s&chan=%s&info=true&src=alexa%s';

# skip very short segments, like eg. some announcements, they seem to cause timing or buffering issues
use constant MIN_EVENT_LENGTH => 15;

my $prefs = preferences('plugin.radioparadise');

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
sub canDirectStreamSong { 0 }

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

	if ( my $blockData = $song->pluginData('blockData') ) {
		# on skip we can get the next track
		if ( $song->pluginData('skip') ) {
			$event = '&event=' . $blockData->{event} . '&elapsed=' . Slim::Player::Source::songTime($client);
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
	main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($result));

	if ($result && ref $result && $result->{song}) {
		my $song = $http->params('song');
		$song->pluginData(blockData => $result);

		if ($prefs->get('skipShortTracks') && $result->{length} * 1 < MIN_EVENT_LENGTH) {
			main::INFOLOG && $log->is_info && $log->info('Event is too short, skipping: ' . $result->{length});
			__PACKAGE__->getNextTrack($song, $http->params('cb'), $http->params('ecb'));
			return;
		}

		# XXX - remove once enabled
		$result->{url} .= '?src=alexa';

		$song->pluginData(ttl => 0);
		$song->streamUrl($result->{url});
	}

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

	if ($ct =~ /aac/i) {
		my ($quality, $format) = _getStreamParams($song->track->url);
		$bitrate = $AAC_BITRATE{$quality} * 1024;
	}
	elsif ($length && $song->pluginData('blockData')) {
		$bitrate = $length * 8 / $song->pluginData('blockData')->{length};
	}

	#       title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, $ct, $length, undef);
}

sub getMetadataFor {
	my ( $class, $client, $url, $forceCurrent ) = @_;

	$client = $client->master;
	my $song = $forceCurrent ? $client->streamingSong() : $client->playingSong();
	return {} unless $song;

	my $pluginDataIsFresh = $song->pluginData('blockData') && $song->pluginData('ttl')
		&& $song->pluginData('blockData')->{url} eq $song->streamUrl
		&& $song->pluginData('ttl') - time > 5;

	if ( (!$client->isPlaying() || $pluginDataIsFresh) && (my $meta = $song->pluginData('meta')) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Returning cached metadata");
		return $meta;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("Refreshing metadata");
	my $icon = $class->getIcon();

	if ( my $cached = $song->pluginData('blockData') ) {
		my $songtime = ($song->streamUrl eq $cached->{url})
			? Slim::Player::Source::songTime($client) * 1000
			: 0;
		my $meta;

		main::INFOLOG && $log->is_info && $log->info(sprintf("Current playtime in block (%s): %.1f", $song->streamUrl, $songtime/1000));

		my ($quality, $format) = _getStreamParams($song->track()->url);

		my $bitrate = '';
		if ($quality == 4 || $format eq 'flac') {
			$bitrate = int($song->bitrate ? ($song->bitrate / 1024) : 850) . 'k VBR FLAC';
		}
		elsif ($quality < 4) {
			$bitrate = $AAC_BITRATE{$quality} . 'k CBR AAC';
		}

		my $currentDuration = 0;

		foreach (sort keys %{$cached->{song}}) {
			my $songdata = $cached->{song}->{$_};
			$songtime -= $songdata->{duration};

			if ($songtime <= 0) {
				$currentDuration = $songdata->{duration} / 1000;

				$meta = {
					artist => $songdata->{artist},
					album  => $songdata->{album},
					title  => $songdata->{title},
					year   => $songdata->{year},
					# this should be songdata->duration only, really, but LMS gets confused in some places, returning the track length in one case, overall length in others.
					duration => $cached->{length} || $currentDuration,
					secs   => $cached->{length} || $currentDuration,
					cover  => $song->pluginData('httpCover') || 'https:' . $cached->{image_base} . $songdata->{cover},
					bitrate=> $bitrate,
					song_id => $songdata->{song_id},
					slideshow => [ split(/,/, ($songdata->{slideshow} || '')) ],
					buttons   => {
						rew => 0,
					},
				};

				last;
			}
		}

		if ($meta) {
			my $notify;

			# if track has not changed yet, check in a few seconds again...
			if ($currentDuration > 20 && abs($songtime) < 20_000 && $song->pluginData('meta') && $song->pluginData('meta')->{song_id} == $meta->{song_id}) {
				main::INFOLOG && $log->is_info && $log->info("Not sure I'm in the right place - scheduling another update soon");
				$song->pluginData(ttl => time() + 5);
			}
			else {
				main::INFOLOG && $log->is_info && $log->info("Scheduling an update for the end of this song: " . int($currentDuration));
				$song->pluginData(ttl => time() + $currentDuration);
				$notify = 1;
			}
			$song->pluginData(meta => $meta);

			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] ) if $notify;

			if ($songtime) {
				Slim::Utils::Timers::killTimers($client, \&_metadataUpdate);
				Slim::Utils::Timers::setTimer($client, $song->pluginData('ttl'), \&_metadataUpdate);
			}

			return $meta;
		}
	}

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
	main::INFOLOG && $log->is_info && $log->info("Scheduled metadata update");
	Slim::Utils::Timers::killTimers($client, \&_metadataUpdate);
	Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
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