#!/usr/bin/perl
#
# PPNZ IRC bot, an IRC bot that parrots RSS feeds as well as other minor tasks.
# Copyright (C) 2010 Peter Ajamian <peter@pajamian.dhs.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
# USA.
#

use strict;
use warnings;

use FindBin;
unshift @INC, $FindBin::Bin;
use ChatBotSettings;

use Encode;
use Data::Dumper;
use Time::HiRes ();
use Date::Parse;
use POSIX qw{strftime tzset};
use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::Feed;

# Set the time zone
$ENV{TZ} = $ChatBotSettings::TimeZone if $ChatBotSettings::TimeZone;
tzset();

my $c = AnyEvent->condvar;

my $host = $ChatBotSettings::Host;
my $port = $ChatBotSettings::Port;
my $info = {
    nick => $ChatBotSettings::Nick,
    user => $ChatBotSettings::Ident,
    real => $ChatBotSettings::RealName,
};

my @channels = map { lc } @ChatBotSettings::Channels;

# Logging
# We call relog when initializing the logs and also whenever we log something new.
# It checks to see if the date has changed and if so it opens new log files under the new date.
my $logdir = $ChatBotSettings::LogDir;
my %log_channels = map {(lc, undef)} @ChatBotSettings::LogChannels;
my $logdate;
sub relog {
    my $today = strftime('%Y%m%d', localtime());
    return if $logdate && $logdate ne $today;
    $logdate = $today;

    while (my($chan, $fh) = each %log_channels) {
	close $fh if $fh;

	my $path = "$logdir/$chan-$logdate";
	if (open($fh, '>>', $path)) {
	    # Enable autoflush for the filehand
	    my $oldfh = select $fh;
	    $| = 1;
	    select $oldfh;
	    # Return the hash element
	    $log_channels{$chan} = $fh;
	}
	else {
	    print "Error: Can't open $path for write/append logging of channel $chan: $! ... disabling logging for $chan\n";
	    delete $log_channels{$chan};
	}
    }
}
relog();

# Call this with the channel and msg to log stuff.  Automatically prepends a timestamp.
sub logtext {
    relog();
    my ($channel, $msg) = @_;
    $channel = lc $channel;
    return unless $log_channels{$channel};

    my $fh = $log_channels{$channel};
    my $time = strftime('%T', localtime());
    print $fh "[$time] $msg\n";
#    print "$channel: [$time] $msg\n";
}

my $con = AnyEvent::IRC::Client->new(send_initial_whois => 1);

# Event callbacks for verious events that log

# Log when nicks join channel:
$con->reg_cb(channel_add => sub {
    my ($self, $msg, $channel, @nicks) = @_;
    if (@nicks > 1) {
	my $nickmodes = $self->channel_list($channel);
	my @modes = (
	    [v => '+'],
	    [h => '%'],
	    [o => '@'],
	    [a => '&'],
	    );

	foreach my $nick (@nicks) {
	    my $onick = $nick;
	    foreach my $mode (@modes) {
		if ($nickmodes->{$onick}{$mode->[0]}) {
		    $nick = $mode->[1] . $nick;
		}
	    }
	}

	logtext $channel, "In channel: @nicks";
    }
    elsif ($self->is_my_nick($nicks[0])) {
	logtext $channel, "Joined $channel as $nicks[0]";
    }
    else {
	logtext $channel, "Joins: @nicks";
    }
	     });

# Log when nicks part channel:
$con->reg_cb(channel_remove => sub {
    my ($self, $ircmsg, $channel, $nick) = @_;
    my $msg = $ircmsg->{params}[1] || $ircmsg->{params}[0];
    my $src = $ircmsg->{params}[2];
    my $cmd = $ircmsg->{command};
    if ($self->is_my_nick($nick)) {
	$nick = 'I';
    }

    my %cmdmap = (
	PART => 'parted',
	QUIT => 'quit',
	KICK => 'was kicked from',
	);
    $cmd = $cmdmap{$cmd} || $cmd;

    my $out = "$nick $cmd $channel";
    $out .= " by $src" if $src;
    $out .= ": $msg";
    logtext $channel, $out;
	     });

$con->reg_cb(nick_change => sub {
    my ($self, $old_nick, $new_nick) = @_;
    my $channels = $self->channel_list();
    while (my ($chan, $nicks) = each %$channels) {
	next unless $nicks->{$new_nick};
	logtext $chan, "Nick change: $old_nick -> $new_nick";
    }
	     });

$con->reg_cb(channel_topic => sub {
    my ($self, $channel, $topic, $who) = @_;
    $topic ||= '';
    $who = ($who ? " set by $who" : '');
    logtext $channel, "Topic$who: $topic";
	     });

# All other commands have to use the debug_recv event
$con->reg_cb(debug_recv => sub {
    my ($self, $ircmsg) = @_;
    my $cmd = $ircmsg->{command};

# Log when there is a mode change.  There is a specific event for this, but stupidly it only gives the
# channel and nick but not the mode changes themselves or who the source of the mode change was.
    if ($cmd eq 'MODE') {
	my $src = $ircmsg->{prefix};
	$src =~ s/!.*//;
	my ($chan, $modes, @nicks) = @{$ircmsg->{params}};

	logtext $chan, "$src sets modes [$chan $modes @nicks]";
    }

# Log who was the person who set the current topic and when (this gets sent by the server on channel join).
    elsif ($cmd eq '333') {
	my (undef, $chan, $nick, $time) = @{$ircmsg->{params}};
	$time = localtime($time);
	logtext $chan, "Topic set by $nick at $time";
    }

#    else { print Dumper($ircmsg) }
});

$con->reg_cb(ctcp_action => sub {
    my ($self, $nick, $channel, $msg, $type) = @_;
    return unless $type eq 'PRIVMSG';
    return if $self->is_my_nick($channel);
    logtext $channel, "Action: $nick $msg";
	     });

$con->reg_cb(publicmsg => sub {
    my ($self, $channel, $ircmsg) = @_;
    my $msg = $ircmsg->{params}[1];
    my ($nick) = $ircmsg->{prefix} =~ /^(.*?)!/;
    logtext $channel, "<$nick> $msg";
	     });

sub say {
    my ($chan, $msg) = @_;
    $con->send_chan($chan, PRIVMSG => $chan, $msg, {priority => 'normal'});

    if ($ChatBotSettings::LogBot) {
	my $nick = $con->nick();
	logtext $chan, "<$nick> $msg";
    }
}

sub ping {
    my ($self, undef, $nick) = @_;
    my $time = Time::HiRes::time();
    $self->send_srv(PRIVMSG => $nick, "\001PING $time\001", {priority => 'high'});
};

# Public chat command list.  This is a hash that includes the lowecase command name (to match the first word of the msg)
# and a subref to process the command.
my $public_commands = {
    '!test' => sub {
	my ($self, $chan, $nick) = @_;
	say $chan, "$nick: It works!";
    },
    '!ping' => \&ping,
};

# Private message command list ... same as above.
my $private_commands = {
    '!test' => sub {
	my ($self, undef, $nick) = @_;
	$self->send_srv(NOTICE => $nick, "It works!", {priority => 'normal'});
    },
    '!ping' => \&ping,
};

my %feeds = %ChatBotSettings::Feeds;

foreach my $feed (values %feeds) {
    $feed = [$feed, 0];
}

my %feedcmds = map { (lc $_->[0], [$_->[0], undef]) } values %feeds;

sub feed_on_request {
    my ($self, undef, $nick, $cmd, $msg) = @_;
    $cmd =~ s/^!//;

    my ($title, $feed) = @{$feedcmds{$cmd}};

    if (!defined $feed) {
	$self->send_srv(NOTICE => $nick, "Feed for $title not loaded yet.  Please try again later.", {priority => 'normal'});
	return;
    }

    # Find the number of entries to display and grab a slice of the entries array.
    my $numentries = (split /\s+/, $msg, 3)[1] || '';
    $numentries =~ s/\D//g;
    $numentries ||= 3;
    my @entries = @{$feed->{rss}{items}};
    $numentries = scalar @entries if $numentries > scalar @entries;
    @entries = reverse @entries[0..$numentries-1];

#    print Dumper($feed);

    foreach my $entry (@entries) {
	my $link = $entry->{link};
	my $etitle = $entry->{title};
	$etitle =~ s/\s+/ /g;
	my $date = $entry->{pubDate};
	$date = str2time $date;
	$date = strftime('%d %b %I:%M%P', localtime($date));
	my $msg = encode('utf8', "$date: [$title] $etitle @ $link");
	$self->send_srv(PRIVMSG => $nick, $msg, {priority => 'low'});
    }
}

foreach (keys %feedcmds) {
    $public_commands->{"!$_"} = \&feed_on_request;
    $private_commands->{"!$_"} = \&feed_on_request;
}

# Overload the send_msg function to make it pad the messages so that we don't flood the server.
# We also add an optional $opt to the end of the args with a priority option that can be
# "low", "normal" or "high".  High priority messages go out right away, by-passing the queue.
# low priority messages are put in a seperate queue and only go out once all high and normal
# priority messages have been sent.  Default is normal unless we are not registered yet in which
# case it is high (so that registration is not throttled).
# Update: We will now maintain a separate queue for each nick and add a method to purge the queue
# for a particular nick.  This allows us to rotate through the various nick queues so that we don't
# block other nicks for an hour because someone sent 120 "!twitter 30" commands in a row.
# We will also add in a method to rename a queue in case someone changes their nick and we will
# purge a queue if the corresponding nick comes back with a "no such nick" error, or if we recieve
# an ident change event for the nick or if the person issues a !stop command.
{
    package AnyEvent::IRC::Client;
    no warnings qw{redefine};

    my @low_nicks;
    my @norm_nicks;
    my %msg_queue;
    my %low_queue;
    my $high_counter = 0;
    my $old_send_msg = \&send_msg;
    my $timer;
    my $timer_cb = sub {
	# Loop so that we can skip purged nicks.
	while (1) {
	    if ($high_counter > 0) {
		$high_counter--;
		return;
	    }

	    if (@norm_nicks) {
		my $nick = shift @norm_nicks;
		if (!$msg_queue{$nick} || !@{$msg_queue{$nick}}) {
		    # The queue for this nick has been purged or run out, skip to the next nick.
		    next;
		}

		my $args = shift @{$msg_queue{$nick}};
		$old_send_msg->(@$args) unless !$args;
#		print "Send NORM: $nick: " . ::Dumper([@{$args}[1..$#$args]]);
		push @norm_nicks, $nick;
		return;
	    }

	    elsif (@low_nicks) {
		my $nick = shift @low_nicks;
		if (!$low_queue{$nick} || !@{$low_queue{$nick}}) {
		    # The queue for this nick has been purged or run out, skip to the next nick.
		    next;
		}

		my $args = shift @{$low_queue{$nick}};
		$old_send_msg->(@$args) unless !$args;
#		print "Send LOW: $nick: " . ::Dumper([@{$args}[1..$#$args]]);
		push @low_nicks, $nick;
		return;
	    }

	    else {
		undef $timer;
		return;
	    }
	}
    };

# Check the message queue and send the message if it's empty, otherwise queue it.
    *send_msg = sub {
	my ($self, $cmd, $nick) = @_;
	my $opt = {};
	if (ref $_[-1]) {
		$opt = pop;
	}

	my $priority = $opt->{priority} || (!$self->{registered} || $cmd !~ /^PRIVMSG|NOTICE$/ ? 'high' : 'normal');
	$nick = lc $nick;

	if (!$timer) {
	    $old_send_msg->(@_);
	    $timer = AnyEvent->timer(
				     after => 3,
				     interval => 3,
				     cb => $timer_cb,
				     );
	    return;
	}
	elsif ($priority eq 'high') {
	    $old_send_msg->(@_);
	    $high_counter++;
#	    print "Queue/Send HIGH: $nick: " . ::Dumper([@_[1..$#_]]);
	}
	elsif ($priority eq 'low') {
	    if (!$low_queue{$nick} || !@{$low_queue{$nick}}) {
		push @low_nicks, $nick;
	    }

	    $low_queue{$nick} ||= [];
	    push @{$low_queue{$nick}}, [@_];
#	    print "Queue LOW: $nick" . ::Dumper([@_[1..$#_]]);
	    return;
	}
	else { # priority is normal
	    if (!$msg_queue{$nick} || !@{$msg_queue{$nick}}) {
		push @norm_nicks, $nick;
	    }

	    $msg_queue{$nick} ||= [];
	    push @{$msg_queue{$nick}}, [@_];
#	    print "Queue NORM: $nick: " . ::Dumper([@_[1..$#_]]);
	    return;
	}
    };

    sub purge_queue {
	my ($self, $nick) = @_;
	$nick = lc $nick;
	delete $msg_queue{$nick};
	delete $low_queue{$nick};
    }

    sub rename_queue {
	my ($self, $oldnick, $newnick) = @_;
	$oldnick = lc $oldnick;
	$newnick = lc $newnick;
	my $norm = delete $msg_queue{$oldnick};
	my $low = delete $low_queue{$oldnick};

	if ($norm) {
	    foreach my $args (@$norm) {
		$args->[2] = $newnick;
	    }
	    $msg_queue{$newnick} = $norm;
	    push @norm_nicks, $newnick;
	}

	if ($low) {
	    foreach my $args (@$low) {
		$args->[2] = $newnick;
	    }
	    $low_queue{$newnick} = $low;
	    push @low_nicks, $newnick;
	}
    }
}

# Events and subs to support the message queue system above
$con->reg_cb(nick_change => sub {
    my ($self, $old_nick, $new_nick) = @_;
    return if $self->is_my_nick($new_nick);
    $self->rename_queue($old_nick, $new_nick);
	     });

sub read_feed {
    my ($feed_reader, $new_entries, $feed, $error) = @_;

    if (defined $error) {
	warn "ERROR: $error\n";
	return;
    }

    my $title = $feeds{$feed_reader->url()}[0];

    # Load the feed up for manual command-based retrieval
    $feedcmds{lc $title}[1] = $feed if $feed;

#    print Dumper($feed);

    # Skip the first reading so we don't display a bunch of old records.
    if (!$feeds{$feed_reader->url()}[1]) {
	$feeds{$feed_reader->url()}[1] = 1;
	return;
    }

    foreach (@$new_entries) {
	my ($hash, $entry) = @$_;
	# $hash a unique hash describing the $entry
	# $entry is the XML::Feed::Entry object of the new entries
	# since the last fetch.

	my $link = $entry->{entry}{link};
	my $etitle = $entry->{entry}{title};
	$etitle =~ s/\s+/ /g;

	my $msg = encode('utf8', "[$title] $etitle @ $link");

	foreach my $chan (@channels) {
	    say $chan, $msg;
	}

#	print Dumper($hash, $entry);
    }
}

while (my ($url, $vals) = each %feeds) {
    $vals->[2] = AnyEvent::Feed->new (
			 url      => $url,
			 interval => 300,
			 on_fetch => \&read_feed,
			 );
  }

$con->reg_cb (connect => sub {
    my ($con, $err) = @_;
    if (defined $err) {
	warn "connect error: $err\n";
	return;
    }
});

# Stuff to do when connected:
$con->reg_cb (registered => sub {
    print "I'm in!\n";
});

$con->reg_cb (disconnect => sub { print "I'm out!\n"; $c->broadcast });

# Register a callback for public commands
$con->reg_cb(publicmsg => sub {
    my ($self, $chan, $ircmsg) = @_;
    my $msg = $ircmsg->{params}[1];
    my ($nick) = $ircmsg->{prefix} =~ /^(.*?)!/;
    my ($cmd) = $msg =~ /^(\S*)/;
    $cmd = lc $cmd;

    return unless $public_commands->{$cmd};

    $public_commands->{$cmd}($self, $chan, $nick, $cmd, $msg, $ircmsg);
});

# Register a callback for private messages
$con->reg_cb(privatemsg => sub {
    my ($self, $tonick, $ircmsg) = @_;
    my $msg = $ircmsg->{params}[1];
    my ($nick) = $ircmsg->{prefix} =~ /^(.*?)!/;
    my ($cmd) = $msg =~ /^(\S*)/;
    $cmd = lc $cmd;

    return unless $private_commands->{$cmd};

    $private_commands->{$cmd}($self, $tonick, $nick, $cmd, $msg, $ircmsg);
});

# Process the ping replies
# Doesn't quite work yet, needs some debugging.
$con->reg_cb(ctcp_ping => sub {
    my ($self, $src, $target, $msg, $type) = @_;
    return unless $type eq 'NOTICE';

    my $elapsed = Time::HiRes::time() - $msg;

    $msg = sprintf('Ping time %01.2f seconds', $elapsed);
#    print Dumper($src, $target, $msg, $type, $elapsed);
    $self->send_srv(NOTICE => $src, $msg, {priority => 'normal'});
});

# Connection loop
while (1) {
	# Identify to NickServ:
	$con->send_srv(PRIVMSG => 'NickServ', "IDENTIFY $ChatBotSettings::NSpass", {priority => 'high'});

	# Join channels:
	$con->send_srv(JOIN => join ',', @channels, {priority => 'high'});

	$con->connect ($host, $port, $info);
	$c->wait;
	$con->disconnect;

	sleep 60;
}
