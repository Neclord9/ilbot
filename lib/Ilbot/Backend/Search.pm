package Ilbot::Backend::Search;
use strict;
use warnings;
use 5.010;

use Lucy::Index::Indexer;
use Lucy::Plan::Schema;
use Lucy::Analysis::PolyAnalyzer;
use Lucy::Plan::FullTextType;

use Lucy::Search::IndexSearcher;
use Lucy::Search::QueryParser;
use Lucy::Search::TermQuery;
use Lucy::Search::ANDQuery;
use Lucy::Search::SortSpec;
use Lucy::Search::SortRule;


use Ilbot::Config;

sub new {
    my ($class, %opt) = @_;
    my %self;
    for my $arg (qw/backend/) {
        die "Missing argument $arg" unless defined $opt{$arg};
        $self{$arg} = $opt{$arg};
    }
    return bless \%self, $class;
}

sub backend { $_[0]->{backend} };

sub indexer {
    my ($self, %opt) = @_;
    die 'Missing argument "channel"' unless $opt{channel};

    $| = 1;
    my $channel = sanitize_channel_for_fs $opt{channel};
    # Create a Schema which defines index fields.
    my $schema = Lucy::Plan::Schema->new;
    my $polyanalyzer = Lucy::Analysis::PolyAnalyzer->new(
        language => config(search => 'language'),
    );
    my $type = Lucy::Plan::FullTextType->new(
        analyzer => $polyanalyzer,
        stored   => 0,
    );
    $schema->spec_field( name => 'ids',     type => Lucy::Plan::StringType->new( indexed => 0, sortable => 0) );
    $schema->spec_field( name => 'day',     type => Lucy::Plan::StringType->new( indexed => 0, sortable => 1));
    $schema->spec_field( name => 'nick',    type => Lucy::Plan::StringType->new( indexed => 1, sortable => 0, stored => 0));
    $schema->spec_field( name => 'line',    type => $type );

    my $indexer = Lucy::Index::Indexer->new(
        schema => $schema,
        index  => join('/', config('search_idx_root'), $channel),
        create => 1,
    );
    return $indexer;
}

sub index_all {
    my $self = shift;
    my $count++;
    for my $channel (@{ $self->backend->channels }) {
        my $b = $self->backend->channel(channel => $channel);
        my $i = $self->indexer(channel => $channel);
        say $channel;
        for my $d (@{ $b->days_and_activity_counts }) {
            my $day = $d->[0];
            print "\r$day";
            my $prev;
            for my $line (@{ $b->lines(day => $day) }) {
                my ($id, $nick, undef, $line) = @$line;
                next unless defined $nick;
                $nick =~ s/^\*\s*//;
                if ($prev && $prev->{nick} eq $nick) {
                    $prev->{ids} .= ",$id";
                    $prev->{line} .= "\n$line";
                }
                else {
                    ++$count, $i->add_doc($prev) if $prev;
                    $prev = {
                        ids     => $id,
                        nick    => $nick,
                        line    => $line,
                        day     => $day,
                    };
                }
            }
            ++$count, $i->add_doc($prev) if $prev;
        }
        print "\rcommitting ...";
        $i->commit;
        print "\roptimizing ...";
        $i->optimize;
        say "\rdone optimizing";
    }
    return $count;
}

sub channel {
    my ($self, %opt) = @_;
    die "Missing argument 'channel'" unless defined $opt{channel};
    Ilbot::Backend::Search::Channel->new(
        backend     => $self->{backend},
        channel     => $opt{channel},
    );

}

package Ilbot::Backend::Search::Channel;

use Ilbot::Config;
use List::Util qw/max min/;

sub new {
    my ($class, %opt) = @_;
    my %self = (
        backend => ($opt{backend} // die "Missing argument 'backend'"),
        channel => sanitize_channel_for_fs($opt{channel} // die "Missing argument 'channel'"),
        orig_channel => $opt{channel},
    );
    bless \%self, $class;
}
sub backend { $_[0]->{backend} };
sub channel { $_[0]->{channel} };

sub _searcher {
    my $self = shift;
    my $channel = $self->{channel};
    return $self->{searcher}{$channel} //= Lucy::Search::IndexSearcher->new(
        index => join('/', config('search_idx_root'), $channel),
    );
}

sub _query {
    my ($self, %opt) = @_;
    die "Missing argument 'q'" unless defined $opt{q};
    my $query = Lucy::Search::QueryParser->new(
        schema => $self->_searcher->get_schema,
    )->parse($opt{q});
    if (length $opt{nick}) {
        my $q_nick = Lucy::Search::TermQuery->new(
            field   => 'nick',
            term    => $opt{nick},
        );
        $query = Lucy::Search::ANDQuery->new(
            children => [$query, $q_nick],
        );
    }
    return $query;
}

sub search_results {
    my ($self, %opt) = @_;
    die "Missing argument 'q'" unless defined $opt{q};
    my $s           = $self->_searcher;
    my $q           = $self->_query(%opt);
    my $offset      = $opt{offset} // 0;
    my $sort_spec   = Lucy::Search::SortSpec->new(
        rules           => [
            Lucy::Search::SortRule->new(
                field   => 'day',
                reverse => 1,
            ),
        ],
    );
    my $wanted = 100;
    my $hits        = $s->hits(
        query           => $q,
        offset          => $offset,
        num_wanted      => $wanted,
        sort_spec       => $sort_spec,
    );
    my %days;
    while (my $h = $hits->next) {
        my $day = $h->{day};
        @{$days{$day}}{ split /,/, $h->{ids} } = undef;
    }
    my @days;
    for my $d (reverse sort keys %days) {
        push @days, $d, $self->_enrich_search_result(
            day     => $d,
            ids     => $days{$d},
        );
    }
    return {
        days    => \@days,
        total   => $hits->total_hits,
        offset  => $offset,
    };
}

sub _enrich_search_result {
    my ($self, %args) = @_;
    for (qw/day ids/) {
        die "Missing argument $_" unless $args{$_};
    }
    my $matched_ids = $args{ids};
    my $context = config(backend => 'search_context');
    my $lines = $self->backend->channel(channel => $self->{orig_channel})->lines(
        day     => $args{day},
    );
    # $lines now contains all the lines for that day.
    # filter out only those lines that matched, plus a bit of context
    # before and after. Since the context can overlap, simply
    # mark all to-be-returned indexes, and then later get the desired
    # lines with a slice
    my @return_idx = (0) x @$lines;
    my @idx = 0..$#$lines;
    for my $idx (@idx) {
        if (exists $matched_ids->{$lines->[$idx][0]}) {
            $lines->[$idx][4] = 1;
            for (max($idx - $context, 0) .. min($#$lines, $idx + $context)) {
                $return_idx[$_] = 1;
            }
        }
    }
    @idx = grep $return_idx[$_], @idx;
    return [ @{$lines}[@idx] ];
};

1;
