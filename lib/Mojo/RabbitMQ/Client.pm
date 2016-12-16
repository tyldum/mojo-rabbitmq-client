package Mojo::RabbitMQ::Client;
use Mojo::Base 'Mojo::EventEmitter';
use Carp qw(croak confess);
use Mojo::URL;
use Mojo::Home;
use Mojo::IOLoop;
use List::MoreUtils qw(none);
use File::Basename 'dirname';
use File::ShareDir qw(dist_file);

use Net::AMQP;
use Net::AMQP::Common qw(:all);

use Mojo::RabbitMQ::Client::Channel;
use Mojo::RabbitMQ::Client::Consumer;
use Mojo::RabbitMQ::Client::LocalQueue;
use Mojo::RabbitMQ::Client::Publisher;

our $VERSION = "0.0.7";

use constant DEBUG => $ENV{MOJO_RABBITMQ_DEBUG} // 0;

has is_open           => 0;
has url               => undef;
has connect_timeout   => sub { $ENV{MOJO_CONNECT_TIMEOUT} // 10 };
has heartbeat_timeout => 60;
has heartbeat_received => 0;    # When did we receive last heartbeat
has heartbeat_sent     => 0;    # When did we sent last heartbeat
has ioloop          => sub { Mojo::IOLoop->singleton };
has max_buffer_size => 16384;
has queue    => sub { Mojo::RabbitMQ::Client::LocalQueue->new };
has channels => sub { {} };
has stream_id   => undef;
has login_user  => '';

sub connect {
  my $self = shift;
  $self->{buffer} = '';

  $self->url(Mojo::URL->new($self->url));

  my $id;
  $id = $self->_connect($self->url, sub { $self->_connected($id, @_) });
  $self->stream_id($id);

  return $id;
}

sub consumer {
  my ($class, @params) = @_;
  croak "consumer is a static method" if ref $class;

  return Mojo::RabbitMQ::Client::Consumer->new(@params);
}

sub publisher {
  my ($class, @params) = @_;
  croak "publisher is a static method" if ref $class;

  return Mojo::RabbitMQ::Client::Publisher->new(@params);
}

sub add_channel {
  my $self    = shift;
  my $channel = shift;

  my $id = $channel->id;
  if ($id and $self->channels->{$id}) {
    return $channel->emit(
      error => 'Channel with id: ' . $id . ' already defined');
  }

  if (not $id) {
    for my $candidate_id (1 .. (2**16 - 1)) {
      next if defined $self->channels->{$candidate_id};
      $id = $candidate_id;
      last;
    }
    unless ($id) {
      return $channel->emit(error => 'Ran out of channel ids');
    }
  }

  $self->channels->{$id} = $channel->id($id)->client($self);

  return $channel;
}

sub open_channel {
  my $self    = shift;
  my $channel = shift;

  return $channel->emit(error => 'Client connection not opened')
    unless $self->is_open;

  $self->add_channel($channel)->open;

  return $self;
}

sub delete_channel {
  my $self = shift;
  return delete $self->channels->{shift};
}

sub close {
  my $self = shift;

  weaken $self;
  $self->_write_expect(
    'Connection::Close'   => {},
    'Connection::CloseOk' => sub {
      $self->emit('close');
      $self->_close;
    },
    sub {
      $self->_close;
    }
  );
}

sub _loop { $_[0]->ioloop }

sub _error {
  my ($self, $id, $err) = @_;

  $self->emit(error => $err);
}

sub _close {
  my $self = shift;
  $self->_loop->stream($self->stream_id)->close_gracefully;
}

sub _handle {
  my ($self, $id, $close) = @_;

  $self->emit('disconnect');

  $self->_loop->remove($id);
}

sub _read {
  my ($self, $id, $chunk) = @_;
  my $chunk_len = length($chunk);

  if ($chunk_len + length($self->{buffer}) > $self->max_buffer_size) {
    $self->{buffer} = '';
    return;
  }

  my $data = $self->{buffer} .= $chunk;

  if (length($data) < 8) {
    return;
  }

  my ($type_id, $channel, $length,) = unpack 'CnN', substr $data, 0, 7;
  if (!defined $type_id || !defined $channel || !defined $length) {
    $self->{buffer} = '';
    return;
  }

  if (length($data) < $length) {
    return;
  }

  weaken $self;
  $self->_loop->next_tick(sub { $self->_parse_frames });

  return;
}

sub _parse_frames {
  my $self = shift;
  my $data = $self->{buffer};

  my ($type_id, $channel, $length,) = unpack 'CnN', substr $data, 0, 7;

  my $stack = substr $self->{buffer}, 0, $length + 8, '';

  my ($frame) = Net::AMQP->parse_raw_frames(\$stack);

  if ($frame->isa('Net::AMQP::Frame::Heartbeat')) {
    $self->heartbeat_received(time());
  }
  elsif ($frame->isa('Net::AMQP::Frame::Method')
    and $frame->method_frame->isa('Net::AMQP::Protocol::Connection::Close'))
  {
    $self->is_open(0);

    $self->_write_frame(Net::AMQP::Protocol::Connection::CloseOk->new());
    $self->emit(disconnect => "Server side disconnection: "
        . $frame->method_frame->{reply_text});
  }
  elsif ($frame->channel == 0) {
    $self->queue->push($frame);
  }
  else {
    my $channel = $self->channels->{$frame->channel};
    if (defined $channel) {
      $channel->_push_queue_or_consume($frame);
    }
    else {
      $self->emit(
        error => "Unknown channel id received: "
          . ($frame->channel // '(undef)'),
        $frame
      );
    }
  }

  weaken $self;
  $self->_loop->next_tick(sub { $self->_parse_frames })
    if length($self->{buffer}) >= 8;
}

sub _connect {
  my ($self, $server, $cb) = @_;

  # Options
  # Parse according to (https://www.rabbitmq.com/uri-spec.html)
  my $url     = $self->url;
  my $query   = $url->query;
  my $options = {
    address  => $url->host,
    port     => $url->port || 5672,
    timeout  => $self->connect_timeout,
    tls      => ($url->scheme =~ /^(amqp|rabbitmq)s$/) ? 1 : 0, # Fallback support for rabbitmq
    tls_ca   => scalar $query->param('ca'),
    tls_cert => scalar $query->param('cert'),
    tls_key  => scalar $query->param('key')
  };
  my $verify = $query->param('verify');
  $options->{tls_verify} = hex $verify if defined $verify;

  # Connect
  weaken $self;
  my $id;
  return $id = $self->_loop->client(
    $options => sub {
      my ($loop, $err, $stream) = @_;

      # Connection error
      return unless $self;
      return $self->_error($id, $err) if $err;

      $self->emit(connect => $stream);

      # Connection established
      $stream->on(timeout => sub { $self->_error($id, 'Inactivity timeout') });
      $stream->on(close => sub { $self->_handle($id, 1) });
      $stream->on(error => sub { $self && $self->_error($id, pop) });
      $stream->on(read => sub { $self->_read($id, pop) });
      $cb->();
    }
  );
}

sub _connected {
  my ($self, $id, $query) = @_;

  # Inactivity timeout
  my $stream = $self->_loop->stream($id)->timeout(0);

  # Store connection information in transaction
  my $handle = $stream->handle;

  # Detect that xml spec was already loaded
  my $loaded = eval { Net::AMQP::Protocol::Connection::StartOk->new; 1 };
  unless ($loaded) {    # Load AMQP specs
    my $file = "amqp0-9-1.stripped.extended.xml";

    # Original spec is in "fixed_amqp0-8.xml"
    my $share = dist_file('Mojo-RabbitMQ-Client', $file);
    Net::AMQP::Protocol->load_xml_spec($share);
  }

  $self->_write($id => Net::AMQP::Protocol->header);

  weaken $self;
  $self->_expect(
    'Connection::Start' => sub {
      my $frame = shift;

      my @mechanisms = split /\s/, $frame->method_frame->mechanisms;
      return $self->emit(error => 'AMQPLAIN is not found in mechanisms')
        if none { $_ eq 'AMQPLAIN' } @mechanisms;

      my @locales = split /\s/, $frame->method_frame->locales;
      return $self->emit(error => 'en_US is not found in locales')
        if none { $_ eq 'en_US' } @locales;

      $self->{_server_properties} = $frame->method_frame->server_properties;

      # Get user & password from $url
      my ($user, $pass) = split /:/, $self->url->userinfo;

      $self->_write_frame(
        Net::AMQP::Protocol::Connection::StartOk->new(
          client_properties => {
            platform    => 'Perl',
            product     => __PACKAGE__,
            information => 'https://github.com/inway/mojo-rabbitmq-client',
            version     => __PACKAGE__->VERSION,
          },
          mechanism => 'AMQPLAIN',
          response  => {LOGIN => $user, PASSWORD => $pass,},
          locale    => 'en_US',
        ),
      );

      $self->login_user($user);
      $self->_tune($id);
    },
    sub {
      $self->emit(error => 'Unable to start connection: ' . shift);
    }
  );
}

sub _tune {
  my $self = shift;

  weaken $self;
  $self->_expect(
    'Connection::Tune' => sub {
      my $frame = shift;

      my $method_frame = $frame->method_frame;
      $self->max_buffer_size($method_frame->frame_max);

      my $heartbeat = $self->heartbeat_timeout || $method_frame->heartbeat;

      # Confirm
      $self->_write_frame(
        Net::AMQP::Protocol::Connection::TuneOk->new(
          channel_max => $method_frame->channel_max,
          frame_max   => $method_frame->frame_max,
          heartbeat   => $heartbeat,
        ),
      );

 # According to https://www.rabbitmq.com/amqp-0-9-1-errata.html
 # The client should start sending heartbeats after receiving a Connection.Tune
 # method, and start monitoring heartbeats after sending Connection.Open.
 # -and-
 # Heartbeat frames are sent about every timeout / 2 seconds. After two missed
 # heartbeats, the peer is considered to be unreachable.
      $self->{heartbeat_tid} = $self->_loop->recurring(
        $heartbeat / 2 => sub {
          return unless time() - $self->heartbeat_sent > $heartbeat / 2;
          $self->_write_frame(Net::AMQP::Frame::Heartbeat->new());
          $self->heartbeat_sent(time());
        }
      ) if $heartbeat;

      $self->_write_expect(
        'Connection::Open' =>
          {virtual_host => $self->url->path, capabilities => '', insist => 1,},
        'Connection::OpenOk' => sub {
          $self->is_open(1);
          $self->emit('open');
        },
        sub {
          $self->emit(error => 'Unable to open connection: ' . shift);
        }
      );
    },
    sub {
      $self->emit(error => 'Unable to tune connection: ' . shift);
    }
  );
}

sub _write_expect {
  my $self = shift;
  my ($method, $args, $exp, $cb, $failure_cb, $channel_id) = @_;
  $method = 'Net::AMQP::Protocol::' . $method;

  $channel_id ||= 0;

  $self->_write_frame(
    Net::AMQP::Frame::Method->new(    #
      method_frame => $method->new(%$args)    #
    ),
    $channel_id
  );

  return $self->_expect($exp, $cb, $failure_cb, $channel_id);
}

sub _expect {
  my $self = shift;
  my ($exp, $cb, $failure_cb, $channel_id) = @_;
  my @expected = ref($exp) eq 'ARRAY' ? @$exp : ($exp);

  $channel_id ||= 0;

  my $queue;
  if (!$channel_id) {
    $queue = $self->queue;
  }
  else {
    my $channel = $self->channels->{$channel_id};
    if (defined $channel) {
      $queue = $channel->queue;
    }
    else {
      $failure_cb->(
        "Unknown channel id received: " . ($channel_id // '(undef)'));
    }
  }

  return unless $queue;

  weaken $self;
  $queue->get(
    sub {
      my $frame = shift;

      return $failure_cb->("Received data is not method frame")
        if not $frame->isa("Net::AMQP::Frame::Method");

      my $method_frame = $frame->method_frame;
      for my $exp (@expected) {
        return $cb->($frame)
          if $method_frame->isa("Net::AMQP::Protocol::" . $exp);
      }

      $failure_cb->("Method is not "
          . join(', ', @expected)
          . ". It's "
          . ref($method_frame));
    }
  );
}

sub _write_frame {
  my $self = shift;
  my $id   = $self->stream_id;
  my ($out, $channel) = @_;

  if ($out->isa('Net::AMQP::Protocol::Base')) {
    $out = $out->frame_wrap;
  }
  $out->channel($channel // 0);

  return $self->_write($id, $out->to_raw_frame);
}

sub _write {
  my $self  = shift @_;
  my $id    = shift @_;
  my $frame = shift @_;

  $self->_loop->stream($id)->write($frame)
    if defined $self->_loop->stream($id);
}

sub DESTROY {
    my $self = shift;
    my $ioloop = $self->ioloop or return;
    my $heartbeat_tid = $self->{heartbeat_tid};

    $ioloop->remove($heartbeat_tid) if $heartbeat_tid;
}

1;

=encoding utf8

=head1 NAME

Mojo::RabbitMQ::Client - Mojo::IOLoop based RabbitMQ client

=head1 SYNOPSIS

  use Mojo::RabbitMQ::Client;

  # Supply URL according to (https://www.rabbitmq.com/uri-spec.html)
  my $client = Mojo::RabbitMQ::Client->new(
    url => 'amqp://guest:guest@127.0.0.1:5672/');

  # Catch all client related errors
  $client->catch(sub { warn "Some error caught in client"; });

  # When connection is in Open state, open new channel
  $client->on(
    open => sub {
      my ($client) = @_;

      # Create a new channel with auto-assigned id
      my $channel = Mojo::RabbitMQ::Client::Channel->new();

      $channel->catch(sub { warn "Error on channel received"; });

      $channel->on(
        open => sub {
          my ($channel) = @_;
          $channel->qos(prefetch_count => 1)->deliver;

          # Publish some example message to test_queue
          my $publish = $channel->publish(
            exchange    => 'test',
            routing_key => 'test_queue',
            body        => 'Test message',
            mandatory   => 0,
            immediate   => 0,
            header      => {}
          );
          # Deliver this message to server
          $publish->deliver;

          # Start consuming messages from test_queue
          my $consumer = $channel->consume(queue => 'test_queue');
          $consumer->on(message => sub { say "Got a message" });
          $consumer->deliver;
        }
      );
      $channel->on(close => sub { $log->error('Channel closed') });

      $client->open_channel($channel);
    }
  );

  # Start connection
  $client->connect();

  # Start Mojo::IOLoop if not running already
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 CONSUMER

  use Mojo::RabbitMQ::Client;
  my $consumer = Mojo::RabbitMQ::Client->consumer(
    url      => 'amqp://guest:guest@127.0.0.1:5672/?exchange=mojo&queue=mojo',
    defaults => {
      qos      => {prefetch_count => 1},
      queue    => {durable        => 1},
      consumer => {no_ack         => 0},
    }
  );

  $consumer->catch(sub { die "Some error caught in Consumer" } );
  $consumer->on('success' => sub { say "Consumer ready" });
  $consumer->on(
    'message' => sub {
      my ($consumer, $message) = @_;

      $consumer->channel->ack($message)->deliver;
    }
  );

  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 PUBLISHER

  use Mojo::RabbitMQ::Client;
  my $publisher = Mojo::RabbitMQ::Client->publisher(
    url => 'amqp://guest:guest@127.0.0.1:5672/?exchange=mojo&queue=mojo'
  );

  $publisher->catch(sub { die "Some error caught in Publisher" } );
  $publisher->on('success' => sub { say "Publisher ready" });

  $publisher->publish('plain text');
  $publisher->publish({encode => { to => 'json'}});

  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head1 DESCRIPTION

L<Mojo::RabbitMQ::Client> is a rewrite of L<AnyEvent::RabbitMQ> to work on top of L<Mojo::IOLoop>.

=head1 EVENTS

L<Mojo::RabbitMQ::Client> inherits all events from L<Mojo::EventEmitter> and can emit the
following new ones.

=head2 connect

  $client->on(connect => sub {
    my ($client, $stream) = @_;
    ...
  });

Emitted when TCP/IP connection with RabbitMQ server is established.

=head2 open

  $client->on(open => sub {
    my ($client) = @_;
    ...
  });

Emitted AMQP protocol Connection.Open-Ok method is received.

=head2 close

  $client->on(close => sub {
    my ($client) = @_;
    ...
  });

Emitted on reception of Connection.Close-Ok method.

=head2 disconnect

  $client->on(close => sub {
    my ($client) = @_;
    ...
  });

Emitted when TCP/IP connection gets disconnected.

=head1 ATTRIBUTES

L<Mojo::RabbitMQ::Client> has following attributes.

=head2 url

  my $url = $client->url;
  $client->url('rabbitmq://...');

=head2 heartbeat_timeout

  my $timeout = $client->heartbeat_timeout;
  $client->heartbeat_timeout(180);

=head1 METHODS

L<Mojo::RabbitMQ::Client> inherits all methods from L<Mojo::EventEmitter> and implements
the following new ones.

=head2 connect

  $client->connect();

Tries to connect to RabbitMQ server and negotiate AMQP protocol.

=head2 close

  $client->close();

=head2 open_channel

  my $channel = Mojo::RabbitMQ::Client::Channel->new();
  ...
  $client->open_channel($channel);

=head2 delete_channel

  my $removed = $client->delete_channel($channel->id);

=head1 SEE ALSO

L<Mojo::RabbitMQ::Client::Channel>, L<Mojo::RabbitMQ::Client::Consumer>, L<Mojo::RabbitMQ::Client::Publisher>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015-2016, Sebastian Podjasek and others

Based on L<AnyEvent::RabbitMQ> - Copyright (C) 2010 Masahito Ikuta, maintained by C<< bobtfish@bobtfish.net >>

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.

=cut
