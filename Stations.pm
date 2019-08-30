package Plugins::RadioParadise::Stations;

use strict;
use JSON::XS::VersionOneAndTwo;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Timers;

use Plugins::RadioParadise::MetadataProvider;

use constant REFRESH_INTERVAL => 86400;
use constant CHANNEL_LIST_URL => 'https://api.radioparadise.com/api/list_chan';
use constant STATION_URL_LIST_URL => 'https://img.radioparadise.com/content/prod/listen/streams/template.html';

my $log = logger('plugin.radioparadise');

my $stations = { map {
	$_->{tag} => $_;
} (
	{
		tag => 'main',
		name => 'PLUGIN_RADIO_PARADISE_MAIN_MIX',
		flac_interactive => 'radioparadise://4.flac',
		flac => 'http://stream.radioparadise.com/flac',
		aac_320 => 'http://stream.radioparadise.com/aac-320',
		aac_128 => 'http://stream.radioparadise.com/aac-128',
		mp3 => 'http://stream.radioparadise.com/mp3-192'
	},
	{
		tag => 'mellow',
		id => 1,
		name => 'PLUGIN_RADIO_PARADISE_MELLOW_MIX',
		flac_interactive => 'radioparadise://4-1.flac',
		flac => 'http://stream.radioparadise.com/mellow-flac',
		aac_320 => 'http://stream.radioparadise.com/mellow-320',
		aac_128 => 'http://stream.radioparadise.com/mellow-128',
		mp3 => 'http://stream.radioparadise.com/mellow-192'
	},
	{
		tag => 'rock',
		id => 2,
		name => 'PLUGIN_RADIO_PARADISE_ROCK_MIX',
		flac_interactive => 'radioparadise://4-2.flac',
		flac => 'http://stream.radioparadise.com/rock-flac',
		aac_320 => 'http://stream.radioparadise.com/rock-320',
		aac_128 => 'http://stream.radioparadise.com/rock-128',
		mp3 => 'http://stream.radioparadise.com/rock-192'
	},
	{
		tag => 'eclectic',
		id => 3,
		name => 'PLUGIN_RADIO_PARADISE_ECLECTIC_MIX',
		flac_interactive => 'radioparadise://4-3.flac',
		flac => 'http://stream.radioparadise.com/eclectic-flac',
		aac_320 => 'http://stream.radioparadise.com/eclectic-320',
		aac_128 => 'http://stream.radioparadise.com/eclectic-128',
		mp3 => 'http://stream.radioparadise.com/eclectic-192'
	},
) };

sub init {
	Slim::Utils::Timers::killTimers(undef, \&init);

	$log->info("Updating channel list...");
	Slim::Networking::SimpleAsyncHTTP->new(
		\&_gotChannelList,
		sub {
			my ($http, $error) = @_;
			$log->error("Failed to look up new channel list: $error" );
		}
	)->get(CHANNEL_LIST_URL);

	Slim::Utils::Timers::setTimer(undef, time + REFRESH_INTERVAL, \&init);
}

sub getChannelList {
	return [ sort {
		$a->{id} <=> $b->{id}
	} values %$stations ];
}

sub getChannelMap {
	return { map {
		$_->{tag} => $_->{id};
	} grep {
		$_->{id};
	} values %$stations };
}

my $maxChannelId;
sub maxChannelId {
	$maxChannelId ||= reverse values %{ getChannelMap() };
	return $maxChannelId;
}

sub _gotChannelList {
	my $http = shift;

	my $stationInfo = eval { from_json($http->content) };

	if ($@) {
		$log->error("Failed to parse channel list: $@");
	}
	else {
		main::INFOLOG && $log->is_info && $log->info("Received station information: " . Data::Dump::dump($stationInfo));
	}

	if ($stationInfo && ref $stationInfo && ref $stationInfo eq 'ARRAY' && grep { !$stations->{$_->{stream_name}} } @$stationInfo) {
		main::INFOLOG && $log->is_info && $log->info("Found new station information: " . Data::Dump::dump(grep { !$stations->{$_->{stream_name}} } @$stationInfo));

		foreach (@$stationInfo) {
			next unless ref $_ and ref $_ eq 'HASH';

			if ($_->{chan} && $_->{stream_name} && $_->{title}) {
				$_->{title} =~ s/^RP //;

				my $station = $stations->{$_->{stream_name}} ||= {
					tag => $_->{stream_name}
				};

				$station->{name} ||= $_->{title};
				$station->{id} = $_->{chan};
				$station->{flac_interactive} = sprintf('radioparadise://4-%s.flac', $_->{chan});
			}
		}

		Slim::Networking::SimpleAsyncHTTP->new(
			\&_gotStationURLList,
			sub {
				my ($http, $error) = @_;
				$log->error("Failed to look up new URL list: $error" );
			}
		)->get(STATION_URL_LIST_URL);
	}
}

sub _gotStationURLList {
	my $http = shift;

	my $content = $http->content;

	my @snippets;
	while ($content =~ m|class="topic_indent">(?<snippet>.*?)</div|sig) {
		push @snippets, $+{snippet}
	}

	my $aac320regex = qr/\/((?!mp3|aac)\w+?)-320/;
	my $aac128regex = qr/\/((?!mp3|aac)\w+?)-128/;
	my $mp3192regex = qr/\/((?!mp3|aac)\w+?)-192/;
	my $flacRegex = qr/\/((?!mp3|aac)\w+?)-flac/;

	my %urls;
	foreach (@snippets) {
		while (m|href="(?<url>.+?)".+?>(?<name>.+?)</a|sig) {
			$urls{$+{url}} = $+{name};
		}
	}

	while (my ($url, $name) = each(%urls)) {
		if ($url =~ $aac128regex) {
			_createStation($url, $1, $name, 'aac_128');
		}
		elsif ($url =~ $aac320regex) {
			_createStation($url, $1, $name, 'aac_320');
		}
		elsif ($url =~ $mp3192regex) {
			_createStation($url, $1, $name, 'mp3');
		}
		elsif ($url =~ $flacRegex) {
			_createStation($url, $1, $name, 'flac');
		}
	}

	Plugins::RadioParadise::MetadataProvider->init();
	$maxChannelId = undef;
}

sub _createStation {
	my ($url, $tag, $name, $quality) = @_;

	my $station = $stations->{$tag} ||= {};
	$station->{name} ||= $name;
	$station->{$quality} = $url;
};


1;