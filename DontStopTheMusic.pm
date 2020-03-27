package Plugins::RadioParadise::DontStopTheMusic;

use strict;

use base qw(Plugins::LastMix::Services::Base);

use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Plugins::RadioParadise::Favorites;

# XXX - make this a pref?
use constant LOWER_LIMIT => 5;
use constant FAVORITES_URL => 'https://api.radioparadise.com/siteapi.php?file=account%%3A%%3Aprofile-favorites&profile_user_id=%s&mode=High&lower_limit=%s&upper_limit=10&list_offset=%s';

my $log = logger('plugin.radioparadise');

sub please {
	my ($client, $cb) = @_;

	if (!Plugins::RadioParadise::Favorites->isSignedIn()) {
		return $cb->($client, []);
	}

	my $userId = Plugins::RadioParadise::Favorites->getUserId() || return $cb->($client, []);

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my ($http) = @_;
			my $result = eval { from_json($http->content) } || {};

			my $seedTracks = $result->{songs} || [];
			Slim::Player::Playlist::fischer_yates_shuffle($seedTracks);

			Plugins::LastMix::DontStopTheMusic::please($client, $cb, [ splice(@$seedTracks, 0, 10) ]);
		},
		sub {
			my ($http, $error) = @_;
			$log->error("Failed to look up user favorites: $error" );
			$cb->($client, []);
		}
	)->get(sprintf(FAVORITES_URL, $userId, LOWER_LIMIT, 0));
}

1;