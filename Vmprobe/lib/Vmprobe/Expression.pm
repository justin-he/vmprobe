package Vmprobe::Expression;

use common::sense;

use Vmprobe::Cache::Snapshot;
use Vmprobe::RunContext;
use Vmprobe::DB::Probe;
use Vmprobe::DB::Entry;


our $parser;

{
    use Regexp::Grammars;

    $parser = qr{
        \A \s* <root_expr=Expr> \s* \z

        ################

        <objrule: Vmprobe::Expression::Expr = Expr>
            <[Term]>+ % <[BinOp]>

        <rule: Term>
            <MATCH=Atom> | \( <MATCH=Expr> \)

        <objrule: Vmprobe::Expression::Atom = Atom>
            <[Method]>+ % [.]

        <token: BinOp>
            [-+|&^]

        <rule: Method>
            <Name=(\w+)> (?: \( <Argument=([-+\s\w,.]+)> \) )?
    };
}

sub new {
    my ($class, $expression) = @_;

    my $self = {};
    bless $self, $class;

    $expression =~ $parser || die "unable to parse expression";

    $self->{root_expr} = $/{root_expr};
    $self->{expression} = $expression;

    return $self;
}

sub eval {
    my ($self, $cb) = @_;

    my $txn = new_lmdb_txn();

    local $self->{entry_db} = Vmprobe::DB::Entry->new($txn);

    my $result_ref = $self->{root_expr}->eval($self);

    $txn->commit;

    return $result_ref;
}

sub on_change {
    my ($self, $cb) = @_;

    $self->{change_cb} = $cb;
}

sub _trigger_change_cb {
    my ($self) = @_;

    my $result_ref = $self->eval();

    $self->{change_cb}->($result_ref)
        if exists $self->{change_cb};
}


{
    package Vmprobe::Expression::Expr;

    sub eval {
        my ($self, $container) = @_;

        my $something_changed;

        for (my $i=0; $i < @{ $self->{Term} }; $i++) {
            my $new_result_ref = $self->{Term}->[$i]->eval($container);

            if ($new_result_ref != $self->{term_result_refs}->[$i]) {
                $something_changed = 1;
                $self->{term_result_refs}->[$i] = $new_result_ref;
            }
        }

        if ($something_changed) {
            $self->{result_ref} = $self->{term_result_refs}->[0];

            for (my $i=0; $i < @{ $self->{BinOp} }; $i++) {
                my $binop_sym = $self->{BinOp}->[$i];
                my $binop_name;

                if ($binop_sym eq '+' || $binop_sym eq '|') {
                    $binop_name = 'union';
                } elsif ($binop_sym eq '&') {
                    $binop_name = 'intersection';
                } elsif ($binop_sym eq '-') {
                    $binop_name = 'subtract';
                } elsif ($binop_sym eq '^') {
                    $binop_name = 'delta';
                } else {
                    die "unrecognized binop sym: $binop_sym";
                }

                my $sub = \&{"Vmprobe::Cache::Snapshot::$binop_name"};
                $self->{result_ref} = \$sub->(${ $self->{result_ref} },
                                              ${ $self->{term_result_refs}->[$i + 1] });
            }
        }

        return $self->{result_ref};
    }
}

{
    package Vmprobe::Expression::Atom;

    sub compile {
        my ($self) = @_;

        $self->{identifier} = $self->{Method}->[0]->{Name};
        $self->{opt} = {};

        for (my $i=1; $i < @{ $self->{Method} }; $i++) {
            my $method = $self->{Method}->[$i];
            $self->{opt}->{$method->{Name}} = $method->{Argument};
        }

        if (length($self->{identifier}) == 16) {
            $self->{type} = 'entry';
        } elsif (length($self->{identifier}) == 22) {
            $self->{type} = 'probe';
        } else {
            die "unsupported identifier: $self->{identifier}";
        }
    }


    sub eval {
        my ($self, $container) = @_;

        $self->compile if !exists $self->{type};

        if ($self->{type} eq 'entry') {
            return $self->{result_ref} if exists $self->{result_ref};

            my $entry = $container->{entry_db}->get($self->{identifier});

            if (keys %{ $entry->{data}->{snapshots} } == 1) {
                $self->{result_ref} = \values %{ $entry->{data}->{snapshots} };
            } else {
                die "entry has multiple flags recorded (" . join(',', keys %{ $entry->{data}->{snapshots} }) . "), please specify a flag in expression"
                    if !exists $self->{opt}->{flag};

                $self->{result_ref} = \$entry->{data}->{snapshots}->{$self->{opt}->{flag}};

                die "entry does not contain the flag $self->{opt}->{flag}"
                    if !defined ${ $self->{result_ref} };
            }

            return $self->{result_ref};
        }
    }


    sub eval_entry {
        my ($self, $container, $entry_id) = @_;
    }
}


1;
