package Plugins::RadioParadise::Plugin;

# TODO:
# - fade stream out before starting different track?
# - parse headers for icy-name =~ /radio paradise/ to not rely on shoutcast IDs

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

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.radioparadise',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_RADIO_PARADISE',
} );

my $prefs = preferences('server');

use constant PSD_URL         => 'http://radioparadise.com/ajax_replace_sb.php?uid=';
use constant DEFAULT_ARTWORK => 'http://www.radioparadise.com/graphics/metadata_2.jpg';
use constant HD_URL          => 'http://www.radioparadise.com/ajax_image.php?width=1280';
use constant HD_INTERVAL     => 15;
use constant HD_PATH         => 'slideshow/720/';

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
my $songUrlRegex  = qr/radioparadise\.com\/temp\/[a-z0-9]+\.mp3/i;
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

	Slim::Formats::RemoteMetadata->registerProvider(
		match => $songUrlRegex,
		func  => sub {
			my ( $client, $url ) = @_;
			my $meta = $client->master->pluginData('rp_psd_trackinfo');
			return ($meta && $meta->{url} eq $url) ? $meta : undef;
		},
	);

	# don't know yet how to deal with initially cleaning the client's playlist from temporary tracks on mysb.com - if ever this is going there anyway :-)
	return if main::SLIM_SERVICE;

	Slim::Control::Request::subscribe(
		sub {
			$class->cleanupPlaylist($_[0]->client, 1);
		},
		[['client'], ['new']]
	);

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
		if ( grep /aac/i, Slim::Player::CapabilitiesHelper::supportedFormats($client) ) {
			unshift @$items, {
				type => 'audio',
				name => $client->string('PLUGIN_RADIO_PARADISE_AAC320'),
				#  O = 32k, 1 = 64k, 2 = 128k, 3 = 320k, 4 = flac all aac.
#				url  => 'radioparadise://3.aac',
				url => 'http://www.radioparadise.com/m3u/aac-320.m3u',
			},{
				type => 'audio',
				name => $client->string('PLUGIN_RADIO_PARADISE_AAC128'),
				#  O = 32k, 1 = 64k, 2 = 128k, 3 = 320k, 4 = flac all aac.
#				url  => 'radioparadise://2.aac',
				url => 'http://www.radioparadise.com/m3u/aac-128.m3u',
			};
		}
		else {
			unshift @$items, {
				type => 'audio',
				name => $client->string('PLUGIN_RADIO_PARADISE_MP3_192'),
				url => 'http://www.radioparadise.com/m3u/mp3-192.m3u',
			};
		}

		unshift @$items, {
			type => 'audio',
			name => $client->string('PLUGIN_RADIO_PARADISE_LOSSLESS'),
			url  => 'radioparadise://4.flac',
		},{
			type => 'audio',
			name => $client->string('PLUGIN_RADIO_PARADISE_LOSSLESS_1'),
			url  => 'radioparadise://4-1.flac',
		},{
			type => 'audio',
			name => $client->string('PLUGIN_RADIO_PARADISE_LOSSLESS_2'),
			url  => 'radioparadise://4-2.flac',
		},{
			type => 'audio',
			name => $client->string('PLUGIN_RADIO_PARADISE_LOSSLESS_3'),
			url  => 'radioparadise://4-3.flac',
		};
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
		$items = [{
			name => $client->string('PLUGIN_RADIO_PARADISE_PSD'),
			url  => \&_playSomethingDifferent,
			nextWindow => 'parent'
		}];

		if ( my $artworkUrl = $client->master->pluginData('rpHD') ) {
			push @$items, {
				name => $client->string('PLUGIN_RADIO_PARADISE_DISABLE_HD'),
				url  => sub {
					my ($client, $cb) = @_;

					Slim::Control::Request::unsubscribe(\&_onPlaylistEvent);
					Slim::Utils::Timers::killTimers(undef, \&_getHDImage);

					Slim::Utils::Cache->new()->set( "remote_image_$url", $artworkUrl, 3600 );
					$song->pluginData( httpCover => $artworkUrl );
					$client->master->pluginData( rpHD => '' );

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

sub _playSomethingDifferent {
	my ($client, $cb) = @_;

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&_playSomethingDifferentSuccess,
		sub {
			$cb->({
				items => [{
					name => $client->string('PLUGIN_RADIO_PARADISE_PSD_FAILED'),
					showBriefly => 1,
				}]
			});
		},
		{
			timeout => 15,
			client  => $client,
			cb      => $cb,
		}
	);

	$http->get(PSD_URL . md5_hex( $client->uuid || $client->id ));
}

sub _playSomethingDifferentSuccess {
	my $http   = shift;
	my $client = $http->params('client');
	my $cb     = $http->params('cb');

	my $result = $http->content;

	# sometimes there's some invalid escaping...
	$result =~ s/\\(['])/$1/g;

	main::INFOLOG && $log->info("Got a new track: $result");

	$client = $client->master;

	$result = eval { from_json( $result ) };

	my $msg;

	if ( $@ ) {
		$log->error($@) if $@;
		$msg = $client->string('PLUGIN_RADIO_PARADISE_PSD_FAILED');
	}
	elsif ( !$result->{url} ) {
		$log->is_debug || $log->error(Data::Dump::dump("Something's wrong with this track information:", $result));
		$msg = $client->string('PLUGIN_RADIO_PARADISE_PSD_FAILED');
	}
	else {
		my $title = $result->{title} . ' - ' . $result->{artist};

		# request highest resolution artwork
		$result->{cover} =~ s/\/m\//\/l\// if $result->{cover};

		# replace default "no artwork" placeholder
		$result->{cover} = DEFAULT_ARTWORK if $result->{cover} =~ m|/0\.jpg$|;

		my $songIndex = Slim::Player::Source::streamingSongIndex($client) || 0;

		# keep track of old settings while we change them
		my $cprefs = $prefs->client($client);
		$client->pluginData('rp_psd_prefs' => {
			repeat => Slim::Player::Playlist::repeat($client),
			transitionType => $cprefs->get('transitionType') || 0,
			transitionDuration => $cprefs->get('transitionDuration') || 2,
		});

		Slim::Player::Playlist::repeat($client, 0);
		$cprefs->set('transitionType', 4);
		$cprefs->set('transitionDuration', 2);

		$client->pluginData('rp_psd_trackinfo' => $result);
		Slim::Control::Request::executeRequest( $client, [ 'playlist', 'insert', $result->{url}, $title ] );
		Slim::Control::Request::executeRequest( $client, [ 'playlist', 'move', $songIndex + 1, $songIndex ] );
		Slim::Control::Request::executeRequest( $client, [ 
			'playlist', 'jump', 
			$songIndex, 
			$result->{fade_in} || 0, 
			0, 
			{ timeOffset => $result->{cue} } || 0
		] );

		Slim::Control::Request::subscribe(\&_playingElseDone, [['playlist'], ['newsong']]);

		$msg = $client->string('JIVE_POPUP_NOW_PLAYING', $title);
	}

	$cb->({
		items => [{
			name => $msg,
			showBriefly => 1,
		}]
	});
}

sub _playingElseDone {
	my $request = shift;
	__PACKAGE__->cleanupPlaylist($request->client);
}

sub _getHDImage {
	my $client = $_[1];

	return unless $client->master->isPlaying;

	Slim::Utils::Timers::killTimers(undef, \&_getHDImage);

	return unless $client->master->pluginData('rpHD');

	main::INFOLOG && $log->info("Get new HD artwork url");

	my $song = $client->streamingSong();

	# cut short if we have slideshow information from the flac's metadata
	if ( $song && $song->pluginData('ttl') && $song->pluginData('meta') && ($song->pluginData('ttl') - time) > 0 && (my $meta = $song->pluginData('meta')) ) {
		if ( $meta->{slideshow} && (my ($nextSlide) = shift @{$meta->{slideshow}} ) ) {
			my $artworkUrl = 'https:' . $song->pluginData('blockData')->{image_base} . HD_PATH . $nextSlide . '.jpg';
			$meta->{cover} = $artworkUrl;
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

sub cleanupPlaylist {
	my ( $class, $client, $force ) = @_;

	return unless $client;

	$client = $client->master;

	my $current = ($client->playingSong && $client->playingSong->track && $client->playingSong->track->url) || '';

	# restore some parameters when we're no longer playing any temporary track
	if ( $force || $current !~ $songUrlRegex ) {
		!$force && main::INFOLOG && $log->info("We're done playing something different. Back to the main stream.");
		Slim::Control::Request::unsubscribe(\&_playingElseDone);
		$client->pluginData('rp_psd_trackinfo' => undef);

		my $oldPrefs = $client->pluginData('rp_psd_prefs');

		if ($oldPrefs) {
			Slim::Player::Playlist::repeat($client, $oldPrefs->{repeat});
			$prefs->client($client)->set('transitionType', $oldPrefs->{transitionType});
			$prefs->client($client)->set('transitionDuration', $oldPrefs->{transitionDuration});

			$client->pluginData('rp_psd_prefs' => undef);
		}
	}

	my $x = 0;
	foreach my $track (@{ Slim::Player::Playlist::playList($client) }) {
		my $url = (blessed $track ? $track->url : $track) || '';

		# remove temporary track, unless it's still playing
		if ( ($force || $current ne $url) && $url =~ $songUrlRegex ) {
			$client->execute([ 'playlist', 'delete', $x ]);
		}
		else {
			$x++;
		}
	}
}

sub shutdownPlugin {
	my $class = shift;

	Slim::Control::Request::unsubscribe(\&_onPlaylistEvent);
	Slim::Control::Request::unsubscribe(\&_playingElseDone);

	return if main::SLIM_SERVICE;

	main::INFOLOG && $log->info('Resetting all Radio Paradise custom streams...');

	foreach (Slim::Player::Client::clients()) {
		$class->cleanupPlaylist($_, 1);
	}
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