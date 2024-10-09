package Plugins::RadioParadise::API;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

# from J.F. (RP), October '24:
# "Some of the calls reference a source id.  It's just for tracking any issues. Yours  is 21."
use constant SOURCE_ID => 21;
use constant AUTH_URL => 'https://api.radioparadise.com/api/auth';
use constant CHANNEL_LIST_URL => 'https://api.radioparadise.com/api/list_chan?C_user_id=%s&ver=2&source=' . SOURCE_ID;
use constant GAPLESS_URL => 'https://api.radioparadise.com/api/gapless?C_user_id=%s&player_id=%s&chan=%s&bitrate=4&numSongs=1&source=' . SOURCE_ID;
use constant FALLBACK_IMG_BASE => '//img.radioparadise.com/';

my $log = logger('plugin.radioparadise');

my ($userId, $imageBase, %maxEventId);

sub auth {
	my ($class, $cb) = @_;

	main::INFOLOG && $log->is_info && $log->info("Authenticating...");
	_get(sub {
		my $result = shift;

		if ($result && ref $result) {
			$userId = $result->{user_id};
		}

		$cb->($userId);
	}, AUTH_URL);
}

sub getRadioStationList {
	my ($class, $cb) = @_;

	main::INFOLOG && $log->is_info && $log->info("Updating channel list...");
	_get(
		sub {
			my $stationInfo = shift;
			$cb->($stationInfo);
		},
		sprintf(CHANNEL_LIST_URL, $userId),
		{
			cache => 15 * 60,
		}
	);
}

sub getNextTrack {
	my ($class, $cb, $args) = @_;

	main::INFOLOG && $log->is_info && $log->info("Getting track information...");

	my $playerId = md5_hex($args->{client});
	my $channel  = $args->{channel} || 0;
	my $url = sprintf(GAPLESS_URL, $userId, $playerId, $channel);

	if (my $event = $args->{event}) {
		$url .= "&event=$event";
	}

	_get(
		sub {
			my $trackInfo = shift;
			$imageBase ||= $trackInfo->{image_base};
			$maxEventId{$channel} = $trackInfo->{max_gapless_event_id} if $trackInfo->{max_gapless_event_id};
			$cb->($trackInfo);
		},
		$url,
	);
}

sub getImageUrl {
	my ($class, $songInfo) = @_;
	return 'https:' . ($imageBase || FALLBACK_IMG_BASE) . ($songInfo->{cover_art} || $songInfo->{cover_large} || $songInfo->{cover_medium} || $songInfo->{cover_small});
}

sub getChannelIdFromUrl {
	my ($class, $url) = @_;
	my ($channel) = $url =~ m{radioparadise://(?:.+?)-?(\d+)?}i;
	return $channel || 0;
}

sub getMaxEventId {
	my ($class, $channel) = @_;
	return $maxEventId{$channel || 0} || -1;
}

sub _get {
	my ($cb, $url, $args) = @_;

	my $params = { 
		cache => 0,
		timeout => 15,
	};

	if (my $ttl = $args->{cache}) {
		$params->{cache} = 1;
		$params->{expires} = $ttl;
	}

	main::INFOLOG && $log->is_info && $log->info("Getting $url");
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;

			my $responseBody = eval { from_json($http->content) };

			if ($@) {
				$log->error("Failed to parse result for $url: $@");
			}

			main::DEBUGLOG && $log->is_debug && $log->debug('Got response:' . Data::Dump::dump($responseBody));

			$cb->($responseBody);
		},
		sub {
			my ($http, $error) = @_;
			$log->error("Failed to get $url: $error" );
			$cb->()
		},
		$params,
	)->get($url);
}



1;