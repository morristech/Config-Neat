=head1 NAME

Config::Neat - Parse/render human-readable configuration files with inheritance and schema validation

=head1 SYNOPSIS

    use Config::Neat;

    my $cfg = Config::Neat->new();
    my $data = $cfg->parse_file('server.nconf');

=head1 DESCRIPTION

This module provides parsing capabilites for the Config::Neat configuration file
format (see the example below). This is a highly readable and clean format inspired
by [nginx configuration files](http://wiki.nginx.org/FullExample).
See L<https://github.com/iafan/Config-Neat/blob/master/sample/readme.nconf>
for the detailed file syntax specification.

Sample configuration file (let's call it 'server.nconf'):

    # Server configuration

    host                    localhost
    port                    8080
    use_ssl                 YES
    supported_mime_types    text/html text/css text/xml text/plain
                            image/gif image/jpeg image/png image/x-icon
                            application/x-javascript

    handler test1 {
        url                 /test1
        class               MyApp::Test
    }

    handler test2 {
        url                 /test2
        class               MyApp::AnotherTest
    }

Sample usage:

    use Config::Neat;

    my $cfg = Config::Neat->new();
    my $data = $cfg->parse_file('server.nconf');

    # now $data contains a parsed hash tree which you can examine

    # consider the sample configuration file above

    my $list = $data->{'server'}->{'supported_mime_types'};
    #
    # $list now is an array reference:
    #     ['text/html', 'text/css', ..., 'application/x-javascript']

    my $handlers = $data->{'handler'};
    map {
        print $_->{url}->as_string, ' maps to ', $_->{class}->as_string
    } @$handlers;

=head1 COPYRIGHT

Copyright (C) 2012-2014 Igor Afanasyev <igor.afanasyev@gmail.com>

=head1 SEE ALSO

L<https://github.com/iafan/Config-Neat>

=cut

package Config::Neat;

our $VERSION = '0.2';

use strict;

use Config::Neat::Array;
use Config::Neat::Util qw(get_next_auto_key read_file);
use Tie::IxHash;

my $LINE_START    = 0;
my $KEY           = 1;
my $WHITESPACE    = 2;
my $VALUE         = 3;
my $LINE_COMMENT  = 4;
my $BLOCK_COMMENT = 5;

#
# Initialize object
#
sub new {
    my ($class) = @_;

    my $self = {
      'cfg' => {}
    };

    bless $self, $class;
    return $self;
}

# Given a string representation of the config, returns a parsed tree
sub parse {
    my ($self, $nconf) = @_;

    my $new = {};
    tie(%$new, 'Tie::IxHash');

    my $o = {
        context            => [$new],
        c                  => undef,

        pos                => 0,

        key                => '',
        values             => Config::Neat::Array->new(),
        value              => undef,
        mode               => $LINE_START,
        previous_mode      => $LINE_START,
        was_backslash      => undef,
        was_slash          => undef,
        was_asterisk       => undef,
        first_value_pos    => 0,
        converted_to_array => undef,
    };

    my $in_raw_mode     = undef;
    my $line            = 1;

    sub end_of_param {
        my $o = shift;

        if ($o->{key} ne '') {
            push @{$o->{values}}, 'YES' if scalar(@{$o->{values}}) == 0;
            my $new = $o->{context}->[$#{$o->{context}}];
            if (exists $new->{$o->{key}}) {
                if (!$o->{converted_to_array}) {
                    $new->{$o->{key}} = Config::Neat::Array->new([$new->{$o->{key}}]);
                    $o->{converted_to_array} = 1;
                }
                $new->{$o->{key}}->push($o->{values});
            } else {
                $new->{$o->{key}} = $o->{values};
            }
            $o->{values} = Config::Neat::Array->new();
            $o->{converted_to_array} = undef;
            $o->{key} = '';
        }
    }

    sub append_text {
        my ($o, $text) = @_;

        if ($o->{mode} == $LINE_START) {
            if (($o->{first_value_pos} > 0) and ($o->{pos} >= $o->{first_value_pos})) {
                $o->{mode} = $VALUE;
            } else {
                end_of_param($o);
                $o->{mode} = $KEY;
                $o->{first_value_pos} = 0;
            }
        } elsif ($o->{mode} == $WHITESPACE) {
            $o->{mode} = $VALUE;
            if ($o->{first_value_pos} == 0) {
                $o->{first_value_pos} = $o->{pos} - 1; # -1 to allow for non-hanging backtick before the first value
            }
        }

        if ($o->{mode} == $KEY) {
            $o->{key} .= $text;
        } elsif ($o->{mode} == $VALUE) {
            $o->{value} .= $text;
        } else {
            die "Unexpected mode $o->{mode}";
        }
    }

    sub process_pending_chars {
        my $o = shift;

        if ($o->{was_slash}) {
            append_text($o, '/');
            $o->{was_slash} = undef;
        }

        if ($o->{was_backslash}) {
            append_text($o, '\\');
            $o->{was_backslash} = undef;
        }
    }

    sub process_char {
        my $o = shift;

        process_pending_chars($o);

        append_text($o, $o->{c});
        $o->{c} = undef;
    }

    sub end_of_value {
        my $o = shift;

        process_pending_chars($o);

        if (defined $o->{value}) {
            push @{$o->{values}}, $o->{value};
            $o->{value} = undef;
        }
    }

    for (my $i = 0, my $l = length($nconf); $i < $l; $i++) {
        my $c = $o->{c} = substr($nconf, $i, 1);
        $o->{pos}++;

        if ($c eq '{') {
            next if ($o->{mode} == $LINE_COMMENT) or ($o->{mode} == $BLOCK_COMMENT);

            if ($in_raw_mode) {
                process_char($o);
                next;
            }

            end_of_value($o);

            if (!$o->{key}) {
                $o->{key} = get_next_auto_key($o->{context}->[$#{$o->{context}}]);
            }

            my $new = {};
            tie(%$new, 'Tie::IxHash');

            my $current_ctx = $o->{context}->[$#{$o->{context}}];
            if (exists $current_ctx->{$o->{key}}) {
                if (ref($current_ctx->{$o->{key}}) ne 'Config::Neat::Array') {
                    $current_ctx->{$o->{key}} = Config::Neat::Array->new([$current_ctx->{$o->{key}}]);
                }
                $current_ctx->{$o->{key}}->push($new);
            } else {
                $current_ctx->{$o->{key}} = $new;
            }

            push @{$o->{context}}, $new;

            # any values preceding the block will be added into it with an empty key value
            if (scalar(@{$o->{values}}) > 0) {
                $new->{''} = $o->{values};
            }

            $o->{values} = Config::Neat::Array->new();
            $o->{key} = '';
            $o->{value} = undef;
            $o->{mode} = $LINE_START;
            $o->{first_value_pos} = 0;

        } elsif ($c eq '}') {
            next if ($o->{mode} == $LINE_COMMENT) or ($o->{mode} == $BLOCK_COMMENT);

            if ($in_raw_mode) {
                process_char($o);
                next;
            }

            end_of_value($o);
            end_of_param($o);

            if (scalar(@{$o->{context}}) == 0) {
                die "Unmatched closing bracket at config line $line position $o->{pos}";
            }
            pop @{$o->{context}};
            $o->{mode} = $WHITESPACE;
            $o->{key} = '';
            $o->{values} = Config::Neat::Array->new();

        } elsif ($c eq '\\') {
            next if ($o->{mode} == $LINE_COMMENT) or ($o->{mode} == $BLOCK_COMMENT);

            process_pending_chars($o);

            $o->{was_backslash} = 1; # do not print current slash, but wait for the next char
            next;

        } elsif ($c eq '/') {
            next if ($o->{mode} == $LINE_COMMENT);
            next if (!$o->{was_asterisk} and $o->{mode} == $BLOCK_COMMENT);

            if ($in_raw_mode) {
                process_char($o);
                next;
            }

            if ($o->{was_asterisk} and ($o->{mode} == $BLOCK_COMMENT)) {
                $o->{mode} = $o->{previous_mode};
                next;
            }

            process_pending_chars($o);

            $o->{was_slash} = 1; # do not print current slash, but wait for the next char
            next;

        } elsif ($c eq '*') {
            next if ($o->{mode} == $LINE_COMMENT);

            if ($o->{mode} == $BLOCK_COMMENT) {
                $o->{was_asterisk} = 1;
                next;
            } else {
                if ($o->{was_slash}) {
                    $o->{was_slash} = undef;
                    $o->{previous_mode} = $o->{mode};
                    $o->{mode} = $BLOCK_COMMENT;
                    next;
                }

                process_char($o);
            }

        } elsif ($c eq '`') {
            next if ($o->{mode} == $LINE_COMMENT) or ($o->{mode} == $BLOCK_COMMENT);

            if ($o->{was_backslash}) {
                $o->{was_backslash} = undef;
                process_char($o);
                next;
            }

            $o->{c} = '';
            process_char($o);

            $in_raw_mode = !$in_raw_mode;

        } elsif (($c eq ' ') or ($c eq "\t")) {
            if ($c eq "\t") {
                warn "Tab symbol at config line $line position $o->{pos} (replace tabs with spaces to ensure proper parsing of multiline parameters)";
            }

            next if ($o->{mode} == $LINE_COMMENT) or ($o->{mode} == $BLOCK_COMMENT);

            if ($in_raw_mode) {
                process_char($o);
                next;
            }

            if ($o->{mode} == $KEY) {
                $o->{mode} = $WHITESPACE;
            } elsif ($o->{mode} == $VALUE) {
                end_of_value($o);
                $o->{mode} = $WHITESPACE;
            }

        } elsif ($c eq "\r") {
            next;

        } elsif ($c eq "\n") {
            $line++;
            $o->{pos} = 0;

            next if ($o->{mode} == $BLOCK_COMMENT);

            if ($in_raw_mode) {
                process_char($o);
                next;
            }

            end_of_value($o);
            $o->{mode} = $LINE_START;

        } elsif ($c eq "#") {
            next if ($o->{mode} == $LINE_COMMENT) or ($o->{mode} == $BLOCK_COMMENT);

            if ($in_raw_mode) {
                process_char($o);
                next;
            }

            if (($o->{mode} == $LINE_START) or ($o->{mode} == $WHITESPACE)) {
                $o->{mode} = $LINE_COMMENT;
            } else {
                process_char($o);
            }

        } else {
            next if ($o->{mode} == $LINE_COMMENT) or ($o->{mode} == $BLOCK_COMMENT);

            process_char($o);
        }

        $o->{was_asterisk} = undef;
    }

    die "Unmatched backtick at config line $line position $o->{pos}" if $in_raw_mode;

    end_of_value($o);
    end_of_param($o);

    return $self->{'cfg'} = $o->{context}->[0];
} # end sub

# Given file name, will read this file in the specified mode (defaults to UTF-8) and parse it
sub parse_file {
    my ($self, $filename, $binmode) = @_;
    return $self->parse(read_file($filename, $binmode));
} # end sub

1; # return true