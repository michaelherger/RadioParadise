package Plugins::RadioParadise::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.radioparadise');

sub name {
	return 'PLUGIN_RADIO_PARADISE';
}

sub prefs {
	return ($prefs, 'skipShortTracks');
}

sub page {
	return 'plugins/RadioParadise/settings.html';
}


1;