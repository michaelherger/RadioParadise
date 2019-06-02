package Plugins::RadioParadise::MetadataProvider;

use strict;

use JSON::XS::VersionOneAndTwo;
use List::Util qw(min);

use Slim::Formats::RemoteMetadata;
use Slim::Music::Info;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use constant ICON     => Plugins::RadioParadise::Plugin->_pluginDataFor('icon');
use constant META_URL => 'https://api.radioparadise.com/api/now_playing?chan=%s';
use constant POLLRATE => 60;

my $flacUrlRegex  = qr/\.radioparadise\.com\/(?:mellow-)?flac/;
my %channelMap    = (
	'mellow' => 1
);

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.radioparadise');

sub init {
	Slim::Formats::RemoteMetadata->registerProvider(
		match => $flacUrlRegex,
		func  => \&provider,
	);
}

sub provider {
	my ( $client, $url ) = @_;

	return defaultMeta(undef, $url) unless $client;

	$client = $client->master;

	if ( !$client->isPlaying && !$client->isPaused ) {
		return defaultMeta( $client, $url );
	}

	if ( my $meta = $client->pluginData('metadata') ) {
		if ( $meta->{_url} eq $url ) {
			if ( !$meta->{title} ) {
				$meta->{title} = Slim::Music::Info::getCurrentTitle($url);
			}

			return $meta;
		}
	}

	if ( !$client->pluginData('fetchingMeta') ) {
		# Fetch metadata in the background
		fetchMetadata( $client, $url );
	}

	return defaultMeta( $client, $url );
}

sub fetchMetadata {
	my ( $client, $url ) = @_;

	Slim::Utils::Timers::killTimers( $client, \&fetchMetadata );

	return unless $client;

	$client = $client->master;
	$client->pluginData( fetchingMeta => 1 );

	# Make sure client is still playing this station
	if ( Slim::Player::Playlist::url($client) ne $url ) {
		main::INFOLOG && $log->is_info && $log->info( $client->id . " no longer playing $url, stopping metadata fetch" );
		return;
	}

	my ($channel) = $url =~ m|/(\w*?)?-?flac$|;
	$channel ||= '';

	main::INFOLOG && $log->is_info && $log->info('This seems to be the ' . ($channel || 'default') . ' mix');

	my $metaUrl = sprintf(META_URL, $channelMap{$channel});

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
	$meta->{bitrate} = '850k VBR';
	$meta->{type} = 'FLAC';

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

sub defaultMeta {
	my ( $client, $url ) = @_;

	return {
		title => Slim::Music::Info::getCurrentTitle($url),
		icon  => ICON,
		cover => ICON,
		type  => cstring($client, 'RADIO'),
		bitrate => 850_000,
		type  => 'FLAC'
	};
}

1;