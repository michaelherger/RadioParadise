package Plugins::RadioParadise::MetadataProvider;

use strict;

use JSON::XS::VersionOneAndTwo;

use Slim::Formats::RemoteMetadata;
use Slim::Music::Info;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::RadioParadise::Stations;

use constant ICON     => Plugins::RadioParadise::Plugin->_pluginDataFor('icon');
use constant META_URL => 'http://api.radioparadise.com/api/now_playing?chan=%s';
use constant POLLRATE => 60;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.radioparadise');

my $channelMap = {};

sub init {
	$channelMap = Plugins::RadioParadise::Stations::getChannelMap();

	my $tags = join('-|', map { s/-mix//; $_ } keys %$channelMap) . '-';
	my $flacUrlRegex  = qr/\.radioparadise\.com\/(?:${tags})?flac/;
	my $lossyUrlRegex  = qr/\.radioparadise\.com\/(?:${tags}|aac-|mp3-)(?:128|192|320)/;

	Slim::Formats::RemoteMetadata->registerProvider(
		match => $flacUrlRegex,
		func  => \&provider,
	);

	# they seem to have a problem with artwork on the icecast strams right now - let's grab it on our end for now
	Slim::Formats::RemoteMetadata->registerParser(
		match => $lossyUrlRegex,
		func  => \&parser,
	);
}

sub provider {
	my ( $client, $url ) = @_;

	if (!$client) {
		main::DEBUGLOG && $log->is_debug && $log->debug('No client object provided');
		return defaultMeta(undef, $url);
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("Getting metadata for $url");

	$client = $client->master;

	if (!$client->pluginData('rpHD')) {
		$cache->set( "remote_image_$url", '', 3600 );
	}

	if ( !$client->isPlaying && !$client->isPaused ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('No metadata lookup - player is not playing');
		return defaultMeta( $client, $url );
	}

	if ( my $meta = $client->pluginData('metadata') ) {
		if ( $meta->{_url} eq $url ) {
			main::INFOLOG && $log->is_info && $log->info("Returning cached data for $url");

			if ( !$meta->{title} ) {
				$meta->{title} = Slim::Music::Info::getCurrentTitle($url);
			}

			return _fixHDMetadata($client, $url, $meta);
		}
	}

	if ( !$client->pluginData('fetchingMeta') ) {
		# Fetch metadata in the background
		fetchMetadata( $client, $url );
	}

	return defaultMeta( $client, $url );
}

sub parser {
	my ( $client, $url, $metadata ) = @_;

	if ($metadata !~ /\bstreamUrl\b/i) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Metadata is missing artwork - let's look it up: ($metadata)");
		provider($client, $url);
	}

	return 0;
}

sub fetchMetadata {
	my ( $client, $url ) = @_;

	Slim::Utils::Timers::killTimers( $client, \&fetchMetadata );

	return unless $client;

	$client = $client->master;
	$client->pluginData( fetchingMeta => 1 );

	# Make sure client is still playing this station
	if ( Slim::Player::Playlist::url($client) ne $url ) {
		$client->pluginData( fetchingMeta => 0 );
		main::INFOLOG && $log->is_info && $log->info( $client->id . " no longer playing $url, stopping metadata fetch: " . Slim::Player::Playlist::url($client) );
		return;
	}

	my ($channel) = $url =~ m{/(\w*?)?-?(?:flac|64|96|128|192|320)};
	$channel ||= '';
	($channel) = grep /$channel/i, keys %$channelMap;

	main::INFOLOG && $log->is_info && $log->info('This seems to be the ' . ($channel || 'Main') . ' mix');

	my $metaUrl = sprintf(META_URL, $channelMap->{$channel});

	main::INFOLOG && $log->is_info && $log->info( "Fetching Radio Paradise metadata from $metaUrl" );

	Slim::Networking::SimpleAsyncHTTP->new(
		\&_gotMetadata,
		\&_gotMetadataError,
		{
			client => $client,
			url    => $url,
		}
	)->get( $metaUrl );
}

sub _gotMetadata {
	my $http   = shift;
	my $client = $http->params('client');
	my $url    = $http->params('url');

	my $meta = eval { from_json($http->content) };

	if ( $@ ) {
		$http->error( $@ );
		_gotMetadataError( $http );
		return;
	}

	$client = $client->master if $client;
	$client->pluginData( fetchingMeta => 0 );

	main::INFOLOG && $log->is_info && $log->info( "Got Radio Paradise metadata: " . Data::Dump::dump($meta) );

	my $ttl = defined $meta->{'time'} ? $meta->{'time'} : POLLRATE;

	$meta->{_url} = $url;
	$meta->{cover} ||= ICON;

	if ($url =~ /\bflac\b/) {
		$meta->{bitrate} = '850k VBR';
		$meta->{type} = 'FLAC';
	}

	$cache->set( "remote_image_$url", $meta->{cover}, 3600 );
	$client->pluginData( metadata => $meta );
	Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );

	Slim::Utils::Timers::setTimer(
		$client,
		time() + $ttl,
		\&fetchMetadata,
		$url,
	);
}

sub _gotMetadataError {
	my $http   = shift;
	my $client = $http->params('client');
	my $url    = $http->params('url');
	my $error  = $http->error;

	$log->warn( "Error fetching RadioParadise metadata: $error" );

	$client = $client->master if $client;
	$client->pluginData( fetchingMeta => 0 );

	# To avoid flooding the servers in the case of errors, we just ignore further
	# metadata for this station if we get an error
	my $meta = defaultMeta( $client, $url );
	$meta->{_url} = $url;

	$client->pluginData( metadata => $meta );

	Slim::Utils::Timers::setTimer(
		$client,
		time() + POLLRATE,
		\&fetchMetadata,
		$url,
	);
}

sub _fixHDMetadata {
	my ($client, $url, $meta) = @_;

	if ( $client && $client->pluginData('rpHD') && (my $hdImage = $cache->get( "remote_image_$url")) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Replacing artwork with HD image: $hdImage");
		$meta = Storable::dclone($meta);
		$meta->{cover} = $meta->{icon} = $hdImage;
	}

	return $meta;
}

sub defaultMeta {
	my ( $client, $url ) = @_;

	return _fixHDMetadata($client, $url, {
		title => Slim::Music::Info::getCurrentTitle($url),
		icon  => ICON,
		cover => ICON,
		type  => cstring($client, 'RADIO'),
		bitrate => 850_000,
		type  => 'FLAC'
	});
}

1;