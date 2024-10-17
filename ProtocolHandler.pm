package Plugins::RadioParadise::ProtocolHandler;

use strict;
use base 'Slim::Player::Protocols::HTTPS';

use Tie::Cache::LRU;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::RadioParadise::API;

my $prefs = preferences('plugin.radioparadise');
my $log = logger('plugin.radioparadise');

tie my %blockData, 'Tie::Cache::LRU', 16;

# To support remote streaming (synced players), we need to subclass Protocols::HTTP
sub new {
	my $class  = shift;
	my $args   = shift;

	my $client = $args->{client};

	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;

	main::DEBUGLOG && $log->debug( 'Remote streaming Radio Paradise track: ' . $streamUrl );

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $args->{song},
		client  => $client,
	} ) || return;

	return $sock;
}

# TODO - investigate wheter we can support seeking
sub canSeek { 0 }
sub isRemote { 1 }
sub canDirectStream { 0 }
sub isRepeatingStream { 1 }
sub contentType { 'audio/flac' };

sub canDoAction {
	my ( $class, $client, $url, $action ) = @_;

	# "stop" seems to be called when a user pressed FWD...
	if ( $action eq 'stop' ) {
		if (my $song = $client->master->streamingSong()) {
			my $channel = Plugins::RadioParadise::API->getChannelIdFromUrl($url);
			my $maxEventId = Plugins::RadioParadise::API->getMaxEventId($channel);
			my $blockData = $class->getBlockData($song);

			# we can only skip x tracks ahead (defined in a response's max event ID)
			if (!($maxEventId > 0 && ($blockData->{event_id} || 0) < $maxEventId)) {
				return 0;
			}
		}
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
	my $action;
	my $channel = Plugins::RadioParadise::API->getChannelIdFromUrl($song->track()->url);

	# if the stream URL is the radioparadise URL, we're starting over - don't restore pevious position
	if ( $song->streamUrl() =~ /^radioparadise:/ ) {
		$action = 'sync_chan_' . $channel;
	}
	elsif ( my $blockData = $class->getBlockData($song) ) {
		$event = $blockData->{event_id};
	}

	Plugins::RadioParadise::API->getNextTrack(sub {
		my $trackInfo = shift || {};

		if (my $songs = $trackInfo->{songs}) {
			if (ref $songs) {
				my $songdata = $songs->[0];
				__PACKAGE__->setBlockData($songdata);
				$song->streamUrl($songdata->{gapless_url});

				Plugins::RadioParadise::API->updateHistory(undef, $songdata, {
					channel => $channel,
					client => $client,
				}) if !$client->isSynced() || Slim::Player::Sync::isMaster($client);

				$successCb->();
				return;
			}
		}

		$log->warn("Failed to get next track?!?");
		main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($trackInfo));
		$errorCb->();
	}, {
		client => $client,
		channel => $channel,
		event => $event,
		action => $action,
	});
}

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	$client = $client->master;
	my $song = $client->playingSong();
	return {} unless $song;

	my $icon = $class->getIcon();
	my $songdata = $class->getBlockData($song);

	# TODO - review?
	my $bitrate = int($song->bitrate ? ($song->bitrate / 1024) : 850) . 'k VBR FLAC';

	if ($songdata) {
		my $meta = {
			artist => $songdata->{artist},
			album  => $songdata->{album},
			title  => $songdata->{title},
			year   => $songdata->{year},
			duration => $songdata->{duration} / 1000,
			secs   => $songdata->{duration} / 1000,
			cover  => Plugins::RadioParadise::API->getImageUrl($songdata),
			bitrate=> $bitrate,
			slideshow => $songdata->{slideshow} || [],
			song_id=> $songdata->{song_id},
			extid  => 'radioparadise:' . $songdata->{song_id},
			buttons   => {
				rew => 0,
			},
		};

		Slim::Music::Info::setDuration($song->track, $meta->{duration});
		main::DEBUGLOG && $log->is_debug && $log->debug("Returning meta data:" . Data::Dump::dump($meta));

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

sub getBlockData {
	my ($class, $song) = @_;
	return $blockData{_cleanupBlockURL($song->streamUrl)};
}

sub setBlockData {
	my ($class, $data, $setStartTime) = @_;

	return unless $data && ref $data && $data->{gapless_url};

	$data->{startPlaybackTime} = time();
	$blockData{_cleanupBlockURL($data->{gapless_url})} = $data;
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