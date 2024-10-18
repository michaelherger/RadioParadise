package Plugins::RadioParadise::DontStopTheMusic;

use strict;

use base qw(Plugins::LastMix::Services::Base);

use JSON::XS::VersionOneAndTwo;
use List::Util qw(min);

use Slim::Utils::Log;
use Plugins::RadioParadise::Favorites;

# XXX - make this a pref?
use constant LOWER_LIMIT => 5;
use constant MAX_ITEMS => 250;
use constant FAVORITES_URL => 'http://api.radioparadise.com/siteapi.php?file=account%%3A%%3Aprofile-favorites&profile_user_id=%s&mode=High&lower_limit=%s&upper_limit=10&list_limit=50&list_offset=%s';

my $log = logger('plugin.radioparadise');

sub please {
	my ($client, $cb) = @_;

	if (!Plugins::RadioParadise::Favorites->isSignedIn()) {
		return $cb->($client, []);
	}

	my $userId = Plugins::RadioParadise::Favorites->getUserId() || return $cb->($client, []);

	my $seedTracks = [];
	getFavorites($userId, 0, sub {
		my ($songs, $num_songs) = @_;

		push @$seedTracks, @$songs;

		if ($num_songs > 50) {
			if ($num_songs > 100 && Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0) {
				require Async::Util;
				my $iterations = int(min($num_songs, MAX_ITEMS) / 50) - 1;
				$iterations++ if $num_songs % 50;

				Async::Util::amap(
					inputs => [1..$iterations],
					action => sub {
						my ($input, $acb) = @_;

						getFavorites($userId, $input * 50, sub {
							my ($moreSongs) = @_;
							push @$seedTracks, @$moreSongs;
							$acb->();
						});
					},
					output => 0,
					cb => sub {
						mixIt($client, $cb, $seedTracks);
					}
				);
			}
			else {
				getFavorites($userId, 50, sub {
					my ($moreSongs) = @_;
					push @$seedTracks, @$moreSongs;

					mixIt($client, $cb, $seedTracks);
				});
			}
		}
		else {
			mixIt($client, $cb, $seedTracks);
		}
	});
}

sub mixIt {
	my ($client, $cb, $seedTracks) = @_;

	Slim::Player::Playlist::fischer_yates_shuffle($seedTracks);
	Plugins::LastMix::DontStopTheMusic::please($client, $cb, [ splice(@$seedTracks, 0, 10) ]);
}

sub getFavorites {
	my ($userId, $offset, $cb) = @_;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my ($http) = @_;
			my $result = eval { from_json($http->content) } || {};

			$cb->($result->{songs} || [], $result->{num_songs});
		},
		sub {
			my ($http, $error) = @_;
			$log->error("Failed to look up user favorites: $error" );
			$cb->([]);
		}
	)->get(sprintf(FAVORITES_URL, $userId, LOWER_LIMIT, $offset || 0));

}

1;