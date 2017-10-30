package Plugins::RadioParadise::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use JSON::XS::VersionOneAndTwo;

use Slim::Networking::SimpleAsyncHTTP;

use Slim::Utils::Log;
use Slim::Utils::Timers;

use constant BASE_URL => 'https://api.radioparadise.com/api/get_block?bitrate=4&info=true&src=alexa';

my $log = logger('plugin.radioparadise');

# To support remote streaming (synced players, slimp3/SB1), we need to subclass Protocols::HTTP
sub new {
	my $class  = shift;
	my $args   = shift;

	my $client = $args->{client};
	
	my $song      = $args->{'song'};
	my $streamUrl = $song->streamUrl() || return;

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $args->{'song'},
		client  => $client,
		bitrate => 850_000,
	} ) || return;
	
	${*$sock}{contentType} = 'audio/x-flac';

	return $sock;
}

sub getFormatForURL { 'flac' }

sub canSeek { 0 }
sub canSkip { 0 }
sub canDirectStreamSong { 0 }

sub isRepeatingStream { 1 }

# Avoid scanning
sub scanUrl {
	my ( $class, $url, $args ) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	
	my $client = $song->master;
	my $event = '';
	
	if ( my $blockData = $song->pluginData('blockData') ) {
		if ( my $endevent = $blockData->{'end_event'} ) {
			$event = '?event=' . $endevent;
		}
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			
			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));
			
			if ($result && ref $result && $result->{song}) {
				# XXX - remove once enabled
				$result->{url} .= '?src=alexa';
				
				$song->pluginData(blockData => $result);
				$song->streamUrl($result->{url});
			}

			$successCb->();
		},
		sub {
			my ($http, $error) = @_;
			
			$log->warn("Error: $error");
			$errorCb->();
		},
		{
			timeout => 15,
		},
	)->get(BASE_URL . $event);
}

# we ignore most of this... only return a fake bitrate, and the content type. Length would create a progress bar
sub parseDirectHeaders {
	my $class   = shift;
	my $client  = shift || return;
	my $url     = shift;
	my @headers = @_;
	
	my $bitrate = 850_000;
	$client = $client->master;
	
	my $length;

	foreach my $header (@headers) {
		if ( $header =~ /^Content-Length:\s*(.*)/i ) {
			$length = $1;
		}
	}
	
	my $song = $client->streamingSong();

	if ($length && $song->pluginData('blockData')) {
		$bitrate = $length * 8 / $song->pluginData('blockData')->{length};
	}

	#       title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, 'audio/x-flac', $length, undef);
}

sub getMetadataFor {
	my ( $class, $client, $url, $forceCurrent ) = @_;
	
	$client = $client->master;
	my $song = $forceCurrent ? $client->streamingSong() : $client->playingSong();
	return {} unless $song;

	if ( $song->pluginData('blockData') && $song->pluginData('blockData')->{url} eq $song->streamUrl && abs($song->pluginData('ttl') - time) > 5 && (my $meta = $song->pluginData('meta')) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Returning cached metadata");
		return $meta;
	}

	my $icon = $class->getIcon();

	if ( my $cached = $song->pluginData('blockData') ) {
		my $songtime = ($song->streamUrl eq $cached->{url})
			? Slim::Player::Source::songTime($client) * 1000
			: 0;
		my $meta;
		
		main::DEBUGLOG && $log->is_debug && $log->debug(sprintf("Current playtime in block (%s): %.1f", $song->streamUrl, $songtime/1000));
		
		foreach (sort keys %{$cached->{song}}) {
			my $songdata = $cached->{song}->{$_};
			$songtime -= $songdata->{duration};

			if ($songtime <= 0) {
				$meta = {
					artist => $songdata->{artist},
					album  => $songdata->{album},
					title  => $songdata->{title},
					year   => $songdata->{year},
					duration => $songdata->{duration},
					secs   => $songdata->{duration},
					cover  => $song->pluginData('httpCover') || 'https:' . $cached->{image_base} . $songdata->{cover},
					bitrate=> int($song->bitrate ? ($song->bitrate / 1000) : 850) . 'k VBR FLAC',
					song_id => $songdata->{song_id},
					slideshow => [ split(/,/, ($songdata->{slideshow} || '')) ],
				};
				
				last;
			}
		}
		
		if ($meta) {
			# if track has not changed yet, check in a few seconds again...
			if (abs($songtime) < 20_000 && $song->pluginData('meta') && $song->pluginData('meta')->{song_id} == $meta->{song_id}) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Not sure I'm in the right place - scheduling another update soon");
				$song->pluginData(ttl => time() + 5);
			}
			else {
				main::DEBUGLOG && $log->is_debug && $log->debug("Scheduling an update for the end of this song: " . int($meta->{duration}/1000));
				$song->pluginData(ttl => time() + $meta->{duration}/1000);
			}
			$song->pluginData(meta => $meta);
			
			if ($songtime) {
				Slim::Utils::Timers::killTimers($client, \&_metadataUpdate);
				Slim::Utils::Timers::setTimer($client, $song->pluginData('ttl'), \&_metadataUpdate);
			}
			
			return $meta;
		}
	}	

	return {
		icon    => $icon,
		cover   => $icon,
		bitrate => '850k VBR FLAC',
		type    => 'FLAC',
		title   => 'Radio Paradise',
		duration=> 0,
		secs    => 0,
		song_id => 0,
	};
}

sub _metadataUpdate {
	my ($client) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("Scheduled metadata update");
	Slim::Utils::Timers::killTimers($client, \&_metadataUpdate);
	Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
}

sub getIcon {
	return Plugins::RadioParadise::Plugin->_pluginDataFor('icon');
}


1;