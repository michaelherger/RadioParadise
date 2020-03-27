package Plugins::RadioParadise::Favorites;

use strict;

use JSON::XS::VersionOneAndTwo;
use List::Util qw(min);
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use constant AUTH_URL => 'https://api.radioparadise.com/api/auth?username=%s&passwd=%s';
use constant RATING_URL => 'https://api.radioparadise.com/api/rating?song_id=%s&rating=%s';

my $log = logger('plugin.radioparadise');

sub init {
	my ($class) = @_;
	$class->refresh();
}

sub signIn {
	my ($class, $username, $password, $cb) = @_;

	if (!$username || !$password) {
		$cb->();
		return;
	}

	Slim::Networking::SimpleAsyncHTTP->new(sub {
		if (!isSignedIn()) {
			$log->warn("Failed to sign in? " . (main::INFOLOG && Data::Dump::dump(@_)));
		}
		elsif (main::DEBUGLOG && $log->is_debug) {
			$log->debug(Data::Dump::dump(@_));
		}

		$cb->(isSignedIn());
	}, sub {
		$log->warn("Failed to sign in? " . (main::INFOLOG && Data::Dump::dump(@_)));
		$cb->(isSignedIn());
	})->get(sprintf(AUTH_URL, uri_escape_utf8($username), uri_escape_utf8($password)));
}

sub signOut {
	Slim::Networking::Async::HTTP->cookie_jar->clear('.radioparadise.com');
	Slim::Networking::Async::HTTP->cookie_jar->clear('api.radioparadise.com');
}

sub refresh {
	my ($class) = @_;

	if ($class->isSignedIn()) {
		# call auth endpoint to refresh the token if possible
		Slim::Networking::SimpleAsyncHTTP->new(sub {}, sub {})->get(AUTH_URL);
	}
}

sub rate {
	my ($class, $songId, $rating, $cb) = @_;

	if (!$songId || !defined $rating || $rating < 0 || $rating > 10) {
		$log->warn(sprintf('Invalid rating (%s) or song ID (%s)', defined $rating ? $rating : 'null', $songId || 0));
		$cb->() if $cb;
		return;
	}

	main::INFOLOG && $log->is_info && $log->info(sprintf('Rating song %s: %s', $songId, $rating));
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $result = eval { from_json($http->content) };

			$@ && $log->error($@);

			if (!$result || !$result->{status} || $result->{status} ne 'success') {
				$log->error('Failed to submit rating: ' . $http->content);
				main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($http));
				$cb->() if $cb;
			}
			elsif ($cb) {
				$cb->(1);
			}
		},
		sub {
			$log->error('Failed to submit rating');
			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump(@_));
			$cb->() if $cb;
		}
	)->get(sprintf(RATING_URL, $songId, $rating));
}

sub isSignedIn {
	my %required = (
		c_validated => 1,
		c_user_id => 1,
		c_passwd => 1,
	);

	my $expiresTS = time() + 720 * 86400;
	Slim::Networking::Async::HTTP->cookie_jar->scan(sub {
		my (undef, $name, undef, undef, $domain, undef, undef, undef, $expires) = @_;
		if ($domain =~ /\bradioparadise\.com/) {
			$expiresTS = min($expiresTS, $expires) if $required{lc($name)};
			delete $required{lc($name)} if $expires > time();
		}
	});

	main::INFOLOG && $log->is_info && !keys %required && $log->info(sprintf('Session still valid for %s seconds', $expiresTS - time()));

	return keys %required ? 0 : $expiresTS;
}

sub getUserId {
	my $userId = '';
	Slim::Networking::Async::HTTP->cookie_jar->scan(sub {
		my (undef, $name, $value, undef, $domain) = @_;
		if ($domain =~ /\bradioparadise\.com/ && lc($name) eq 'c_user_id') {
			$userId = $value;
		}
	});

	return $userId;
}

1;