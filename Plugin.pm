package Plugins::RadioParadise::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

use vars qw($VERSION);
use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);

use Slim::Menu::TrackInfo;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use constant STATIONS => [
	{
		id => 'main',
		name => 'PLUGIN_RADIO_PARADISE_MAIN_MIX',
		flac_interactive => 'radioparadise://4.flac',
		flac => 'http://stream.radioparadise.com/flac',
		aac_320 => 'http://stream.radioparadise.com/aac-320',
		aac_128 => 'http://stream.radioparadise.com/aac-128',
		mp3 => 'http://stream.radioparadise.com/mp3-192'
	},
	{
		id => 'mellow',
		name => 'PLUGIN_RADIO_PARADISE_MELLOW_MIX',
		flac_interactive => 'radioparadise://4-1.flac',
		flac => 'http://stream.radioparadise.com/mellow-flac',
		aac_320 => 'http://stream.radioparadise.com/mellow-320',
		aac_128 => 'http://stream.radioparadise.com/mellow-128',
		mp3 => 'http://stream.radioparadise.com/mellow-192'
	},
	{
		id => 'rock',
		name => 'PLUGIN_RADIO_PARADISE_ROCK_MIX',
		flac_interactive => 'radioparadise://4-2.flac',
		flac => 'http://stream.radioparadise.com/rock-flac',
		aac_320 => 'http://stream.radioparadise.com/rock-320',
		aac_128 => 'http://stream.radioparadise.com/rock-128',
		mp3 => 'http://stream.radioparadise.com/rock-192'
	},
	{
		id => 'eclectic',
		name => 'PLUGIN_RADIO_PARADISE_ECLECTIC_MIX',
		flac_interactive => 'radioparadise://4-3.flac',
		flac => 'http://stream.radioparadise.com/eclectic-flac',
		aac_320 => 'http://stream.radioparadise.com/eclectic-320',
		aac_128 => 'http://stream.radioparadise.com/eclectic-128',
		mp3 => 'http://stream.radioparadise.com/eclectic-192'
	},
];

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.radioparadise',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_RADIO_PARADISE',
} );

my $prefs = preferences('server');

use constant DEFAULT_ARTWORK => 'http://www.radioparadise.com/graphics/metadata_2.jpg';
use constant HD_URL          => 'http://www.radioparadise.com/ajax_image.php?width=1280';
use constant HD_INTERVAL     => 15;
use constant HD_PATH         => 'slideshow/720/';

# most lossless features require SSL
my $canLossless = Slim::Networking::Async::HTTP->hasSSL();

if ($canLossless) {
	eval {
		require Slim::Player::Protocols::HTTPS;
	};

	$canLossless = 0 if $@;
}

# s13606 is the TuneIn ID for RP - Shoutcast URLs are recognized by the cover URL. Hopefully.
#my $radioUrlRegex = qr/(?:\.radioparadise\.com|id=s13606|shoutcast\.com.*id=(785339|101265|1595911|674983|308768|1604072|1646896|1695633|856611))/i;
my $radioUrlRegex = qr/(?:^radioparadise:|\.radioparadise\.com|id=s13606|radio_paradise)/i;
my $songImgRegex  = qr/radioparadise\.com\/graphics\/covers\/[sml]\/.*/;
my $hdImgRegex    = qr/radioparadise\.com.*\/graphics\/tv_img/;

my $timer;
my $useLocalImageproxy;

sub initPlugin {
	my $class = shift;

	$VERSION = $class->_pluginDataFor('version');

	Slim::Menu::TrackInfo->registerInfoProvider( radioparadise => (
		isa => 'top',
		func   => \&nowPlayingInfoMenu,
	) );

	# try to load custom artwork handler - requires recent LMS 7.8 with new image proxy
	eval {
		require Slim::Web::ImageProxy;

		Slim::Web::ImageProxy->registerHandler(
			match => $songImgRegex,
			func  => sub {
				my ($url, $spec) = @_;

				my $size = Slim::Web::ImageProxy->getRightSize($spec, {
					70  => 's',
					160 => 'm',
					300 => 'l',
				}) || 'l';
				$url =~ s/\/[sml]\//\/$size\//;

				return $url;
			},
		);

		Slim::Web::ImageProxy->registerHandler(
			match => $hdImgRegex,
			func  => sub {
				my ($url, $spec) = @_;

				my $size = Slim::Web::ImageProxy->getRightSize($spec, {
# don't use smaller than 640, as we pre-cache 640 anyway
#					320  => '/320',
					640  => '/640',
				}) || '';
				$url =~ s/\/640\//$size\//;
				return $url;
			},
		);

		main::DEBUGLOG && $log->debug("Successfully registered image proxy for Radio Paradise artwork");

		$useLocalImageproxy = 1;
	} if $prefs->get('useLocalImageproxy');

	if ($canLossless) {
		Slim::Player::ProtocolHandlers->registerHandler(
			radioparadise => 'Plugins::RadioParadise::ProtocolHandler'
		);

		# metadata for the "regular" FLAC stream
		require Plugins::RadioParadise::MetadataProvider;
		Plugins::RadioParadise::MetadataProvider->init();
	}
	else {
		$log->warn(string('PLUGIN_RADIO_PARADISE_MISSING_SSL'));
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'radioparadise',
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);
}


sub getDisplayName { 'PLUGIN_RADIO_PARADISE' }
sub playerMenu {}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if (!$client) {
		$cb->([{ name => string('NO_PLAYER_FOUND') }]);
		return;
	}

	$client = $client->master;
	my $song = $client->playingSong();
	my $track = $song->track if $song;
	my $url = $track->url if $track;

	my $items = nowPlayingInfoMenu($client, $url, $track) || [];

	if ($canLossless) {
		my $canAAC = grep(/aac/i, Slim::Player::CapabilitiesHelper::supportedFormats($client)) ? 1 : 0;

		my %stations;
		foreach (reverse @{STATIONS()}) {
			my $stationMenu = [{
				type => 'audio',
				name => $client->string('PLUGIN_RADIO_PARADISE_LOSSLESS_INTERACTIVE'),
				url  => $_->{flac_interactive},
			},{
				type => 'audio',
				name => $client->string('PLUGIN_RADIO_PARADISE_LOSSLESS'),
				url  => $_->{flac},
			}];

			if ($canAAC) {
				push @$stationMenu, {
					type => 'audio',
					name => $client->string('PLUGIN_RADIO_PARADISE_AAC320'),
					url => $_->{aac_320},
				},{
					type => 'audio',
					name => $client->string('PLUGIN_RADIO_PARADISE_AAC128'),
					url => $_->{aac_128},
				};
			}
			else {
				push @$stationMenu, {
					type => 'audio',
					name => $client->string('PLUGIN_RADIO_PARADISE_MP3_192'),
					url => $_->{mp3},
				};
			}

			unshift @$items, {
				type => 'outline',
				name => $client->string($_->{name}),
				items => $stationMenu
			};
		}
	}
	else {
		unshift @$items, {
			name => $client->string('PLUGIN_RADIO_PARADISE_MISSING_SSL'),
			type => 'textarea'
		};
	}

	$cb->({
		items => $items,
	});
}

sub nowPlayingInfoMenu {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	my $items = [];
	$remoteMeta ||= {};

	# only continue if we're playing RP (either URL matches, or the cover url is pointing to radioparadise.com)
	return unless isRP($url, $remoteMeta->{cover});

	# add item to controll the current playlist
	my $song = $client->master->playingSong;
	if ( $song && $song->track->id == $track->id ) {
		if ( my $artworkUrl = $client->master->pluginData('rpHD') ) {
			push @$items, {
				name => $client->string('PLUGIN_RADIO_PARADISE_DISABLE_HD'),
				url  => sub {
					my ($client, $cb) = @_;

					Slim::Control::Request::unsubscribe(\&_onPlaylistEvent);
					Slim::Utils::Timers::killTimers(undef, \&_getHDImage);

					Slim::Utils::Cache->new()->set( "remote_image_$url", $artworkUrl, 3600 );
					$song->pluginData( httpCover => '' );
					$client->master->pluginData( rpHD => '' );

					main::INFOLOG && $log->is_info && $log->info("Ending HD mode for $url");

					Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );

					$cb->({
						items => [{
							name => $client->string('PLUGIN_RADIO_PARADISE_HD_DISABLED'),
							showBriefly => 1,
						}]
					});
				},
				nextWindow => 'parent'
			}
		}
		else {
			push @$items, {
				name => $client->string('PLUGIN_RADIO_PARADISE_ENABLE_HD'),
				url  => sub {
					my ($client, $cb) = @_;

					$client->master->pluginData( rpHD => $remoteMeta->{cover} );

					_getHDImage(undef, $client);

					# listen to playlist events to make sure we correctly initialise/disable HD downloading
					Slim::Control::Request::subscribe(\&_onPlaylistEvent, [['playlist'], ['newsong', 'pause', 'stop', 'play']]);

					$cb->({
						items => [{
							name => $client->string('PLUGIN_RADIO_PARADISE_HD_ENABLED'),
							showBriefly => 1,
						}]
					});
				},
				nextWindow => 'parent'
			}
		}
	}

	return $items;
}

sub _getHDImage {
	my $client = $_[1];

	return unless $client->master->isPlaying;

	Slim::Utils::Timers::killTimers(undef, \&_getHDImage);

	return unless $client->master->pluginData('rpHD');

	main::INFOLOG && $log->info("Get new HD artwork url");

	my $song = $client->streamingSong();

	# cut short if we have slideshow information from the flac's metadata
	if ( $song && $song->pluginData('lastSongId')        # && ($song->pluginData('ttl') - time) > 0 
		&& (my $slideshow = $song->pluginData('slideshow')) && (my $blockData = Plugins::RadioParadise::ProtocolHandler->getBlockData($song)) 
	) {
		if ( ref $slideshow && (my $nextSlide = shift @$slideshow) && (my $imageBase = $blockData->{image_base}) ) {
			$song->pluginData(slideshow => $slideshow);
			my $artworkUrl = 'https:' . $imageBase . HD_PATH . $nextSlide . '.jpg';
			_setArtwork($client, $artworkUrl);

			Slim::Utils::Timers::killTimers(undef, \&_getHDImage);
			$timer = Slim::Utils::Timers::setTimer(undef, time + HD_INTERVAL, \&_getHDImage, $client);
			return;
		}
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		\&_gotHDImageResponse,
		\&_gotHDImageResponse,
		{
			timeout => 5,
			client  => $client,
		}
	)->get(HD_URL);
}

sub _gotHDImageResponse {
	my $http   = shift;
	my $client = $http->params('client');
	$client = $client->master;

	my $artworkUrl = $http->content;

	main::DEBUGLOG && $log->is_debug && $log->debug("Got HD artwork info: $artworkUrl");

	if ($artworkUrl && $artworkUrl =~ /^http/) {
		$artworkUrl =~ s/ .*//g;
		$artworkUrl =~ s/\n//g;

		main::INFOLOG && $log->info("Got new HD artwork url: $artworkUrl");

		_setArtwork($client, $artworkUrl);
	}

	Slim::Utils::Timers::killTimers(undef, \&_getHDImage);
	$timer = Slim::Utils::Timers::setTimer(undef, time + HD_INTERVAL, \&_getHDImage, $client);
}

sub _setArtwork {
	my ($client, $artworkUrl) = @_;

	my $setArtwork = sub {
		my $song = $client->playingSong() || return;

		# keep track of track artwork
		my $meta = Slim::Player::Protocols::HTTP->getMetadataFor($client, $song->track->url, 1);
		if ( $meta && $meta->{cover} && $meta->{cover} =~ $songImgRegex ) {
			main::INFOLOG && $log->info('Track info changed - keep track of cover art URL: ' . $meta->{cover});
			$client->master->pluginData( rpHD => $meta->{cover} );
		}

		Slim::Utils::Cache->new()->set( "remote_image_" . $song->track->url, $artworkUrl, 3600 );
		$song->pluginData( httpCover => $artworkUrl );
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
	};

	if ( $useLocalImageproxy ) {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$setArtwork->() if $_[0]->code == 200;
				main::INFOLOG && $log->info("Pre-cached new HD artwork for $artworkUrl");
			},
			sub {},
			{
				timeout => 5,
				cache   => 1,
			}
		)->get($artworkUrl);
	}
	else {
		$setArtwork->();
	}
}

sub _onPlaylistEvent {
	my $request = shift;
	my $client  = $request->client || return;

	my $song = $client->playingSong();

	if ( main::INFOLOG && $log->is_info ) {
		$log->info('Dealing with "' . $request->getRequestString . '" event');
		$log->info('Currently playing: ' . ($song ? $song->track->url : 'unk'));
	}

	if ( $song && isRP($song->track->url) ) {
		if ( $client->master->pluginData('rpHD') && $client->isPlaying) {
			$timer = Slim::Utils::Timers::setTimer(undef, time + HD_INTERVAL, \&_getHDImage, $client);
		}
	}
	# we're no longer playing RP - kill the download timers if there are any
	elsif ($song && $timer) {
		$timer = undef;
		Slim::Utils::Timers::killTimers(undef, \&_getHDImage);
	}
}

sub isRP {
	my ($url, $coverUrl) = @_;

	$coverUrl ||= '';

	return $url =~ $radioUrlRegex || $coverUrl =~ /radioparadise\.com/
}

sub _pluginDataFor {
	my $class = shift;
	my $key   = shift;

	my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class);

	if ($pluginData && ref($pluginData) && $pluginData->{$key}) {
		return $pluginData->{$key};
	}

	return undef;
}

1;
