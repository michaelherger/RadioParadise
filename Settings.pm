package Plugins::RadioParadise::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::RadioParadise::Favorites;
use Plugins::RadioParadise::Stations;

my $prefs = preferences('plugin.radioparadise');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RADIO_PARADISE');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/RadioParadise/settings.html');
}

sub prefs {
	return ($prefs, qw(showInRadioMenu replayGain));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ( grep /^delete_creds$/, keys %$params ) {
		Plugins::RadioParadise::Favorites->signOut();
		Plugins::RadioParadise::Stations->init();
	}

	if ($params->{'saveSettings'} && $params->{'rp_username'} && $params->{'rp_password'}) {
		Plugins::RadioParadise::Favorites->signIn($params->{'rp_username'}, $params->{'rp_password'}, sub {
			Plugins::RadioParadise::Stations->init();
			$callback->( $client, $params, $class->SUPER::handler($client, $params), @args );
		});
		return;
	}

	return $class->SUPER::handler($client, $params);
}

sub beforeRender {
	my ($class, $params, $client) = @_;

	if (my $expires = Plugins::RadioParadise::Favorites->isSignedIn()) {
		$params->{rp_valid_thru} = Slim::Utils::DateTime::shortDateF($expires);

		Slim::Networking::Async::HTTP->cookie_jar->scan(sub {
			my (undef, $name, $value, undef, $domain) = @_;
			if ($domain =~ /\bradioparadise\.com/ && lc($name) eq 'c_username') {
				$params->{rp_username} = $value;
			}
		});
	}
}

1;

__END__
