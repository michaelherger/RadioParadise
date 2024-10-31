package Plugins::RadioParadise::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

use vars qw($VERSION);
use Scalar::Util qw(blessed);

use Slim::Menu::TrackInfo;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.radioparadise',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_RADIO_PARADISE',
} );

my $serverprefs = preferences('server');
my $prefs = preferences('plugin.radioparadise');

use constant DEFAULT_ARTWORK => 'http://www.radioparadise.com/graphics/metadata_2.jpg';
use constant HD_URL          => 'http://www.radioparadise.com/ajax_image.php?width=1280';
use constant HD_INTERVAL     => 15;
use constant HD_PATH         => 'slideshow/720/';
use constant INFO_URL        => 'http://radioparadise.com/music/song/%s';

# most lossless features require SSL
my $canLossless = Slim::Networking::Async::HTTP->hasSSL();

if ($canLossless) {
	eval {
		require Slim::Player::Protocols::HTTPS;
	};

	$canLossless = 0 if $@;
}

$prefs->init({
	showInRadioMenu => 0,
	replayGain => 0
});

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
					640  => '/640',
				}) || '';
				$url =~ s/\/640\//$size\//;
				return $url;
			},
		);

		main::DEBUGLOG && $log->debug("Successfully registered image proxy for Radio Paradise artwork");

		$useLocalImageproxy = 1;
	} if $serverprefs->get('useLocalImageproxy');

	if ($canLossless) {
		Slim::Player::ProtocolHandlers->registerHandler(
			radioparadise => 'Plugins::RadioParadise::ProtocolHandler'
		);

		# metadata for the "regular" FLAC stream
		require Plugins::RadioParadise::MetadataProvider;
		Plugins::RadioParadise::MetadataProvider->init();

		require Plugins::RadioParadise::Stations;
		Plugins::RadioParadise::Stations->init();

		require Plugins::RadioParadise::Favorites;
		Plugins::RadioParadise::Favorites->init();

		Slim::Control::Request::subscribe(\&_onPauseEvent, [['playlist'], ['pause','stop']]);

		if (main::WEBUI) {
			require Plugins::RadioParadise::Settings;
			Plugins::RadioParadise::Settings->new();
		}
	}
	else {
		$log->warn(string('PLUGIN_RADIO_PARADISE_MISSING_SSL'));
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'radioparadise',
		menu   => 'radios',
		is_app => $prefs->get('showInRadioMenu') ? 0 : 1,
		weight => 1,
	);
}

sub postinitPlugin { if ($canLossless) {
	my $class = shift;

	# add support for LastMix - if it's installed
	if ( Slim::Utils::PluginManager->isEnabled('Plugins::LastMix::Plugin') ) {
		eval {
			require Plugins::LastMix::Services;
		};

		if (!$@) {
			main::INFOLOG && $log->info("LastMix plugin is available - let's use it!");
			require Slim::Plugin::DontStopTheMusic::Plugin;
			require Plugins::RadioParadise::DontStopTheMusic;
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RADIO_PARADISE_LASTMIX', \&Plugins::RadioParadise::DontStopTheMusic::please);
		}
	}
} }

sub getDisplayName { 'PLUGIN_RADIO_PARADISE' }
sub playerMenu {}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if (!$client) {
		$cb->([{ name => string('NO_PLAYER_FOUND') }]);
		return;
	}

	$client = $client->master;

	my $items = [];

	if ($canLossless) {
		my $canAAC = grep(/aac/i, Slim::Player::CapabilitiesHelper::supportedFormats($client)) ? 1 : 0;

		my %stations;
		foreach (reverse @{Plugins::RadioParadise::Stations::getChannelList()}) {
			my $prefix = getString($client, $_->{name}) . ' - ';

			my $stationMenu = [];

			push @$stationMenu, {
				type => 'audio',
				name => $prefix . $client->string('PLUGIN_RADIO_PARADISE_LOSSLESS_INTERACTIVE'),
				url  => $_->{flac_interactive},
			} if $_->{flac_interactive};

			push @$stationMenu, {
				type => 'audio',
				name => $prefix . $client->string('PLUGIN_RADIO_PARADISE_LOSSLESS'),
				url  => $_->{flac},
			} if $_->{flac};

			if ($canAAC && ($_->{aac_128} || $_->{aac_320})) {
				push @$stationMenu, {
					type => 'audio',
					name => $prefix . $client->string('PLUGIN_RADIO_PARADISE_AAC320'),
					url => $_->{aac_320},
				} if $_->{aac_320};

				push @$stationMenu,{
					type => 'audio',
					name => $prefix . $client->string('PLUGIN_RADIO_PARADISE_AAC128'),
					url => $_->{aac_128},
				} if $_->{aac_320};
			}
			elsif ($_->{mp3}) {
				push @$stationMenu, {
					type => 'audio',
					name => $prefix . $client->string('PLUGIN_RADIO_PARADISE_MP3_192'),
					url => $_->{mp3},
				};
			}

			unshift @$items, $#{$stationMenu} ? {
				type => 'outline',
				name => getString($client, $_->{name}),
				items => $stationMenu
			} : $stationMenu->[0];
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

sub getString {
	my ($client, $stringOrToken) = @_;

	return $stringOrToken if $stringOrToken =~ /(?:[a-z]|\s)/;
	return $client->string($stringOrToken);
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

		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

		if ( $handler && $handler eq 'Plugins::RadioParadise::ProtocolHandler' ) {
			my $meta = $handler->getMetadataFor( $client, $url );

			if ( $meta->{song_id} ) {
				push @$items, {
					name => $client->string('PLUGIN_RADIO_PARADISE_SONG_ON_RP'),
					weblink => sprintf(INFO_URL, $meta->{song_id})
				} if canWeblink($client);

				push @$items, {
					name => $client->string('PLUGIN_RADIO_PARADISE_SONG_ID', $meta->{song_id}),
					type => 'text'
				};

				my @ratings;
				for (my $x = 10; $x > 0; $x--) {
					push @ratings, {
						name => $client->string('PLUGIN_RADIO_PARADISE_RATING_' . $x),
						url => \&_rate,
						passthrough => [{
							id => $meta->{song_id},
							rating => $x
						}],
						nextWindow => 'parent'
					};
				}

				push @$items, {
					name => $client->string('PLUGIN_RADIO_PARADISE_RATE'),
					type => 'outline',
					items => \@ratings,
				};
			}
		}
	}

	return $items;
}

# Keep in sync with Qobuz plugin
my $WEBLINK_SUPPORTED_UA_RE = qr/\b(?:iPeng|SqueezePad|OrangeSqueeze|OpenSqueeze|Squeezer|Squeeze-Control)\b/i;
my $WEBBROWSER_UA_RE = qr/\b(?:FireFox|Chrome|Safari)\b/i;

sub canWeblink {
	my ($client) = @_;
	return $client && (!$client->controllerUA || ($client->controllerUA =~ $WEBLINK_SUPPORTED_UA_RE || $client->controllerUA =~ $WEBBROWSER_UA_RE));
}

sub _rate {
	my ($client, $cb, $params, $args) = @_;

	if (!$args->{id} || !$args->{rating}) {
		return $cb->([{
			name => $client->string('PLUGIN_RADIO_PARADISE_RATE_FAILED'),
			showBriefly => 1,
		}]);
	}

	Plugins::RadioParadise::Favorites->rate($args->{id}, $args->{rating}, sub {
		$cb->([{
			name => $client->string($_[0] ? 'PLUGIN_RADIO_PARADISE_RATED' : 'PLUGIN_RADIO_PARADISE_RATE_FAILED'),
			showBriefly => 1,
		}]);
	});
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

sub _onPauseEvent {
	my $request = shift;
	my $client  = $request->client || return;

	return if $client->isSynced() && !Slim::Player::Sync::isMaster($client);

	my $song = $client->playingSong();

	if (!$song && blessed $song && $song->track) {
		main::INFOLOG && $log->is_info && $log->info("Not a Radio Paradise stream");
		return;
	}

	my $url = $song->track->url || '' if $song;
	if ($url && $url =~ /^radioparadise:/) {
		my $channel = Plugins::RadioParadise::API->getChannelIdFromUrl($url);
		my $songInfo = Plugins::RadioParadise::ProtocolHandler->getBlockData($song);

		# XXXX - We don't currently allow pausing. Unfortunately the position in a
		# stopped stream is always 0 - keep track ourselves... or fall back to random position...
		my $position = time() - $songInfo->{startPlaybackTime};
		$position = $song->duration * rand(1) if $position > $song->duration;

		Plugins::RadioParadise::API->updatePause(undef, $songInfo, {
			client => $client->id,
			channel => $channel,
			position => $position,
		});
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
