package Plugins::RadioParadise::API;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use URI ();
use URI::QueryParam;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

# from J.F. (RP), October '24:
# "Some of the calls reference a source id.  It's just for tracking any issues. Yours  is 21."
use constant SOURCE_ID => 21;
use constant BASE_URL => 'http://api.radioparadise.com';
use constant AUTH_URL => BASE_URL . '/api/auth';
use constant CHANNEL_LIST_URL => BASE_URL . '/api/list_chan?C_user_id=%s&ver=3&source=' . SOURCE_ID;
use constant GAPLESS_URL => BASE_URL . '/api/gapless';
use constant UPDATE_HISTORY_URL => BASE_URL . '/api/update_history';
use constant UPDATE_PAUSE_URL => BASE_URL . '/api/update_pause';
use constant FALLBACK_IMG_BASE => '//img.radioparadise.com/';

my $log = logger('plugin.radioparadise');

my ($userId, $countryCode, $imageBase, %maxEventId);

sub auth {
	my ($class, $cb) = @_;

	main::INFOLOG && $log->is_info && $log->info("Authenticating...");
	_get(sub {
		my $result = shift;

		if ($result && ref $result) {
			$userId = $result->{user_id};
			$countryCode = $result->{country_code};
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

	my $playerId = _getPlayerId($args->{client});
	my $channel  = $args->{channel} || 0;

	my $queryParams = {
		C_user_id => $userId,
		player_id => $playerId,
		chan      => $channel,
		bitrate   => 4,
		numSongs  => 1,
		source    => SOURCE_ID,
	};

	if (my $event = $args->{event}) {
		$queryParams->{event} = $event;
	}

	if (my $action = $args->{action}) {
		$queryParams->{action} = $action;
	}

	_get(
		sub {
			my $trackInfo = shift;
			$imageBase ||= $trackInfo->{image_base};
			$maxEventId{$channel} = $trackInfo->{max_gapless_event_id} if $trackInfo->{max_gapless_event_id};
			$cb->($trackInfo);
		},
		GAPLESS_URL,
		{
			queryParams => $queryParams
		}
	);
}

sub updateHistory {
	my ($class, $cb, $songInfo, $args) = @_;

	return unless $songInfo && $songInfo->{event_id} && $songInfo->{song_id} && $args->{client};

	my $playerId = _getPlayerId($args->{client});
	my $channel  = $args->{channel} || 0;
	my $position = $args->{position} || 0;

	_get(
		sub { $cb->(@_) if $cb; },
		UPDATE_HISTORY_URL,
		{
			queryParams => {
				C_user_id => $userId,
				song_id   => $songInfo->{song_id},
				player_id => $playerId,
				event     => $songInfo->{event_id},
				chan      => $channel,
				country_code => $countryCode,
				'time'    => time() - $position,
				playtime_secs => time(),
				source    => SOURCE_ID,
			},
		}
	);
}

sub updatePause {
	my ($class, $cb, $songInfo, $args) = @_;

	return unless $songInfo && $songInfo->{event_id} && $songInfo->{song_id} && $args->{client};

	my $playerId = _getPlayerId($args->{client});
	my $channel  = $args->{channel} || 0;
	my $position = $args->{position} || 0;

	_get(
		sub { $cb->(@_) if $cb; },
		UPDATE_PAUSE_URL,
		{
			queryParams => {
				pause     => $position * 1000,
				C_user_id => $userId,
				player_id => $playerId,
				event     => $songInfo->{event_id},
				chan      => $channel,
				playtime_secs => time(),
				source    => SOURCE_ID,
			},
		}
	);
}

sub getImageUrl {
	my ($class, $songInfo) = @_;
	return 'http:' . ($imageBase || FALLBACK_IMG_BASE) . ($songInfo->{cover_art} || $songInfo->{cover_large} || $songInfo->{cover_medium} || $songInfo->{cover_small});
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

sub _getPlayerId {
	my ($client) = shift;
	return md5_hex(ref $client ? $client->id : $client);
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

	if (my $queryParams = $args->{queryParams}) {
		my $uri = URI->new($url);
		$uri->query_form(%$queryParams);
		$url = $uri->as_string();
	}

	main::INFOLOG && $log->is_info && $log->info("Getting $url");
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;

			my $responseBody = eval { from_json($http->content) };

			if ($@ && $http->content) {
				$log->error("Failed to parse result for $url: $@");
				main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($http));
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