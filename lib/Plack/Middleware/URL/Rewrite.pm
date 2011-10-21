package Plack::Middleware::URL::Rewrite;
use strict;
use warnings;

our $VERSION = '0.01_01';

use parent 'Plack::Middleware';
use Plack::Util::Accessor qw(conf ttl debug);
use URI;
use URI::QueryParam;
use Config::Mini::WithRegexp;
use Carp;

sub call {
    my $self = shift;
    my $env  = shift;
    
    # если не инициализирован или протухла инфа о реврайтах
    $self->_init if (not $self->{modified} or ($self->ttl and time > $self->{reolad_time}));
    
    # ищём реврайт если были правила для реврайта
    $self->_make_rewrite($env) if $self->{has_rule};

    $self->app->($env);
}

sub _init {
    my $self = shift;
    
    $self->{modified} ||= 0;
    my $modified = [stat($self->conf)]->[9];
    if ($self->{modified} eq $modified) {
        $self->{reolad_time} = time + $self->ttl if $self->ttl;
        return;
    }
    
    my $cnf = eval{Config::Mini::WithRegexp->new($self->conf)};
    if ($@) {
        carp $@;
        return;
    }
    
    my @map = ();
    for my $rule ($cnf->section) {
        my $data = $cnf->section($rule);
        my $desc = {};
        for (keys %$data) {
            if (/^req\.url\.segments[(\d+)]$/) {
                # описание сегмента ури
                $desc->{req}->{url}->{segment}->[$1] = $data->{$_};
            } elsif ($_ eq 'req.url.segments.others') {
                $desc->{req}->{url}->{segments_others} = $data->{$_};
            } elsif ($_ eq 'req.url.params.others') {
                $desc->{req}->{url}->{params_others} = $data->{$_};
            } elsif ($_ eq 'rew.url.params.others') {
                $desc->{rew}->{url}->{params_others} = 1;
            } elsif ($_ eq 'rew.url.segments.others') {
                $desc->{rew}->{url}->{segments_others} = 1;
            } elsif (/^req\.url\.params.(.+?)/) {
                $desc->{req}->{url}->{param}->{$1} = $data->{$_};
            } elsif (/^rew\.url\.segments[(\d+)]/) {
                my $i = $1;
                if ($data->{$_} =~ /^req\.url\.segments[(\d+)]\.match\(\$(\d+)\)$/) {
                    my $segment_target = $1;
                    my $match_target = $2;
                    if (ref $desc->{req}->{url}->{segment}->[$segment_target] eq 'Regexp' and $match_target-1 > -1) {
                        # сегмент описан
                        $desc->{rew}->{url}->{segment}->[$i] = sub {
                            $_->{segments}->{$segment_target}->[$match_target-1] || '';
                        };
                    } else {
                        # ссылка на сегмент, который не был описан или был описан не регекспом
                        croak __PACKAGE__.": found error in describe '$_ = ".$data->{$_}."'";
                        %$desc = ();
                        last;
                    }
                } else {
                    # simple value
                    my $val = $data->{$_};
                    $desc->{rew}->{url}->{segment}->[$i] = sub {$val};
                }
            } elsif (/^rew\.url\.params\.(.+?)/) {
            	my $i = $1;
            	if ($data->{$_} =~ /req\.url\.params\.(.+?)\.match\($(\d+)\)/) {
                    my $param_target = $1;
                    my $match_target = $2;
                    if (ref $desc->{req}->{url}->{param}->{$param_target} eq 'Regexp' and $match_target-1 > -1) {
                        # параметр описан
                        $desc->{rew}->{url}->{param}->{$i} = sub {
                            $_->{params}->{$param_target}->[$match_target-1] || '';
                        };
                    } else {
                        # ссылка на сегмент, который не был описан или был описан не регекспом
                        croak __PACKAGE__.": found error in describe '$_ = ".$data->{$_}."'";
                        %$desc = ();
                        last;
                    }                    
                } else {
                    # simple value
                    my $val = $data->{$_};
                    $desc->{rew}->{url}->{param}->{$i} = sub {$val};
                }
            }
        }
        
        if (keys %$desc) {
        	# set default
        	$desc->{req}->{url}->{segments_others} = 0 unless defined $desc->{req}->{url}->{segments_others}; 
        	$desc->{req}->{url}->{params_others} ||= 1; 
        	
        	$desc->{rew}->{url}->{segments_others} = 0 unless defined $desc->{rew}->{url}->{segments_others};
        	$desc->{rew}->{url}->{params_others} ||=1;
        	
        	# chek root
        	
        	# set any match
        	
	        push @map, $desc; 
        };
        
        
    }
    
    
    $self->{modified} = $modified;
    $self->{has_rule} = @map ? 1 : 0;
    
    return;
}

sub _make_rewrite {
    my $self = shift;
    my $env  = shift;
    
    my $uri = URI->new($env->{REQUEST_URI});
    my @segment = map {length $_ ? $_ : '/'} $uri->path_segments;
    shift @segment;
    
    # не найдено дерево для данного числа сегментов
    my $tree = $self->{rules}->{depth}->{scalar @segment}; 
    return unless $tree; 
    
    # собёрм параметры в хэш
    my $params = {};
    for ($uri->query_param) {
        my @param = $uri->query_param($_);
        $params->{$_} = [@param];
    }
    
    my $rewrite_url = __make_rewrite($tree, $params, @segment);
    
    if ($rewrite_url) {
        # TODO: check default (path can't be null)
        $env->{REQUEST_URI}     = "$rewrite_url";
        $env->{PATH_INFO}       = $rewrite_url->path;
        $env->{QUERY_STRING}    = $rewrite_url->query || '';
        carp __PACKAGE__.": rewrite '$uri' to '$rewrite_url'" if $self->debug;
    } elsif ($self->debug) {
        carp __PACKAGE__.": not found rewrite rule fot '$uri'";
    }
    
    return;
}

sub __make_rewrite {
    my ($tree, $params, @segment) = @_;
    
    
    return;
}

1;
__END__
# description /foo/123456Jhon/bar/?baz=2011

[my rewrite bla-bla /foo/123456Jhon/bar/?baz=2011trach&daz=1 => /foo/123456/Jhon/bar/?baz=2011&daz=1 ]
req.url.segments[0]     = foo
req.url.segments[1]     =~ /^(\d{0,6})(\w+)$/
req.url.segments.others = 1
req.url.params.baz      =~ /^(\d{4})/

rew.url.segments[0]     = foo
rew.url.segments[1]     = req.url.segments[1].match($1)
rew.url.segments[2]     = req.url.segments[1].match($2)
rew.url.segments.others = 1
rew.url.params.baz      = req.url.params.baz.match($1)  
rew.url.params.others   = 1