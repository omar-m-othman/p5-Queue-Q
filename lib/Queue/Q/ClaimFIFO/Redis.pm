package Queue::Q::ClaimFIFO::Redis;
use strict;
use warnings;
use Carp qw(croak);

use Digest::SHA1;
use Redis;

use Redis::ScriptCache;

use Queue::Q::ClaimFIFO;
use parent 'Queue::Q::ClaimFIFO';

use Class::XSAccessor {
    getters => [qw(server port queue_name db _redis_conn _script_cache)],
};

use constant CLAIMED_SUFFIX => '_claimed';
use constant STORAGE_SUFFIX => '_storage';

# in: queue_name, itemkey, value
# out: nothing
our $EnqueueScript = qq#
    redis.call('lpush', KEYS[1], ARGV[1]);
    redis.call('hset', KEYS[1] .. "${\STORAGE_SUFFIX()}", ARGV[1], ARGV[2]);
#;
our $EnqueueScriptSHA = Digest::SHA1::sha1_hex($EnqueueScript);

# in: queue_name, time
# out: itemkey, value
our $ClaimScript = qq#
    local itemkey = redis.call('rpop', KEYS[1]);
    local data = redis.call('hget', KEYS[1] .. "${\STORAGE_SUFFIX()}", itemkey);
    redis.call('zadd', KEYS[1] .. "${\CLAIMED_SUFFIX()}", ARGV[1], itemkey);
    return {itemkey, data};
#;
our $ClaimScriptSHA = Digest::SHA1::sha1_hex($ClaimScript);

# in: queue_name, itemkey
# out: nothing
our $FinishScript = qq#
    redis.call('hdel', KEYS[1] .. "${\STORAGE_SUFFIX()}", ARGV[1]);
    redis.call('zrem', KEYS[1] .. "${\CLAIMED_SUFFIX()}", ARGV[1]);
#;
our $FinishScriptSHA = Digest::SHA1::sha1_hex($FinishScript);

sub new {
    my ($class, %params) = @_;
    for (qw(server port queue_name)) {
        croak("Need '$_' parameter")
            if not exists $params{$_};
    }

    my $self = bless({
        (map {$_ => $params{$_}} qw(server port queue_name) ),
        db => $params{db} || 0,
        _redis_conn => undef,
        _script_ok => 0, # not yet known if lua script available
    } => $class);

    $self->{_redis_conn} = Redis->new(
        %{$params{redis_options} || {}},
        encoding => undef, # force undef for binary data
        server => join(":", $self->server, $self->port),
    );
    $self->{_script_cache}
        = Redis::ScriptCache->new(redis_conn => $self->_redis_conn);

    $self->_redis_conn->select($self->db) if $self->db;

    return $self;
}


sub enqueue_item {
    my $self = shift;
    croak("Need exactly one item to enqeue")
        if not @_ == 1;

    my $item = shift;
    $self->_script_cache->run_script(
        $EnqueueScriptSHA,
        [1, $self->queue_name, $item->_key, $item->_serialized_data],
        \$EnqueueScript
    );
}

sub enqueue_items {
    my $self = shift;
    return if not @_;

    # FIXME, move loop onto the server or pipeline if possible!
    my $qn = $self->queue_name;
    for (0..$#_) {
        my $key  = $_[$_]->_key;
        my $data = $_[$_]->_serialized_data;

        $self->_script_cache->run_script(
            $EnqueueScriptSHA,
            [1, $qn, $key, $data],
            \$EnqueueScript
        );
    }
}

sub claim_item {
    my $self = shift;

    my ($key, $serialized_data) = $self->_script_cache->run_script(
        $ClaimScriptSHA,
        [1, $self->queue_name, time()],
        \$ClaimScript
    );

    my $item = Queue::Q::ClaimFIFO::Item->new(
        _serialized_data => $serialized_data,
        _key => $key,
    );
    $item->{item_data} = $item->_deserialize_data($serialized_data);

    return $item;
}

sub claim_items {
    my $self = shift;
    $self->_assert_script_ok if not $self->{_script_ok};

    my $n = shift || 1;
    my @items;

    for (1..$n) {
        # TODO Lua script for multiple items!
        my ($key, $serialized_data) = $self->_script_cache->run_script(
            $ClaimScriptSHA,
            [1, $self->queue_name, time()],
            \$ClaimScript
        );

        my $item = Queue::Q::ClaimFIFO::Item->new(
            _serialized_data => $serialized_data,
            _key => $key,
        );
        $item->{item_data} = $item->_deserialize_data($serialized_data);
        push @items, $item;
    }

    return @items;
}

sub mark_item_as_done {
    my ($self, $item) = @_;

    my $key = $item->_key;
    $self->_script_cache->run_script(
        $FinishScriptSHA,
        [1, $self->queue_name, $key],
        \$FinishScript,
    );
}

sub mark_items_as_done {
    my ($self) = shift;

    foreach (@_) {
        # TODO Lua script for multiple items!
        my $key = $_->_key;
        $self->_script_cache->run_script(
            $FinishScriptSHA,
            [1, $self->queue_name, $key],
            \$FinishScript,
        );
    }
}

sub flush_queue {
    my $self = shift;
    $self->_redis_conn->del($self->queue_name);
    $self->_redis_conn->del($self->queue_name . CLAIMED_SUFFIX);
    $self->_redis_conn->del($self->queue_name . STORAGE_SUFFIX);
}

1;
