package Plugins::RadioParadise::Favorites;

use strict;

use JSON::XS::VersionOneAndTwo;
use List::Util qw(min);

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
	my ($class) = @_;

	# TODO - only run if credentials are given

	Slim::Networking::SimpleAsyncHTTP->new(sub {
		warn Data::Dump::dump(@_, 'success');
		warn isSignedIn();
	}, sub {
		warn Data::Dump::dump(@_, 'failure');
		warn isSignedIn();
	})->get(sprintf(AUTH_URL, '', ''));
}

sub refresh {
	my ($class) = @_;

	# call auth endpoint to refresh the token if possible
	Slim::Networking::SimpleAsyncHTTP->new(sub {
		$class->signIn() if !$class->isSignedIn();
	}, sub {
		$class->signIn() if !$class->isSignedIn();
	})->get(AUTH_URL);
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
		c_passwd => ,
	);

	my $expiresTS = time() + 720 * 86400;
	Slim::Networking::Async::HTTP->cookie_jar->scan(sub {
		my (undef, $name, undef, undef, undef, undef, undef, undef, $expires) = @_;
		$expiresTS = min($expiresTS, $expires) if $required{lc($name)};
		delete $required{lc($name)} if $expires > time();
	});

	main::INFOLOG && $log->is_info && !keys %required && $log->info(sprintf('Session still valid for %s seconds', $expiresTS - time()));

	return keys %required ? 0 : $expiresTS;
}

1;