package Plack::Middleware::URL::Rewrite;
use strict;
use warnings;

our $VERSION = '0.01_01';

use parent 'Plack::Middleware';
use Plack::Util::Accessor qw(conf ttl debug);
use URI;
use URI::QueryParam;
use Config::Mini::WithRegexp;
use Scalar::Util qw();
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
    $cnf->regexp_prepare;
    
    # skip old values
    $self->{segments_tree} = {};
    $self->{params_tree}   = {};
    $self->{rewrite_rules} = {}; 

    for my $rule ($cnf->section) {
        my $data = $cnf->section($rule);
        my $desc = {};        
        for (keys %$data) {
        	next if (!$_ or /^_/ or Scalar::Util::blessed($_));
            if (/^req\.segments\[(\d+)\]$/) {
                # описание сегмента ури
                $desc->{req}->{segment}->[$1] = $data->{$_};
            } elsif ($_ eq 'req.segments.others') {
                $desc->{req}->{segments_others} = $data->{$_};
            } elsif ($_ eq 'req.params.others') {
                $desc->{req}->{params_others} = $data->{$_};
            } elsif ($_ eq 'rew.params.others') {
                $desc->{rew}->{params_others} = 1;
            } elsif ($_ eq 'rew.segments.others') {
                $desc->{rew}->{segments_others} = 1;
            } elsif (/^req\.params\.(.+?)$/) {
                $desc->{req}->{param}->{$1} = $data->{$_};
            } elsif (/^rew\.segments\[(\d+)\]$/) {
                my $i = $1;
                if ($data->{$_} =~ /^req\.segments\[(\d+)\]\.match\(\$(\d+)\)$/) {
                    my $segment_target = $1;
                    my $match_target = $2;                    
                    if ($data->{'__req.segments['.$segment_target.']'} and ref $data->{'__req.segments['.$segment_target.']'}->[0] eq 'Regexp' and $match_target-1 > -1) {
                        # сегмент описан
                        $desc->{rew}->{segment}->[$i] = sub {
                            $_[0]->{segments}->{$segment_target}->[$match_target] || '';
                        };
                    } else {
                        # ссылка на сегмент, который не был описан или был описан не регекспом
                        croak __PACKAGE__.": found error in describe '$_ = ".$data->{$_}."'";
                        %$desc = ();
                        last;
                    }
                } else {
                    # simple value for segment
                    my $val = $data->{$_};
                    $desc->{rew}->{segment}->[$i] = $val eq '/' ? '' : $val;
                }
            } elsif (/^rew\.params\.(.+?)$/) {
            	my $i = $1;
            	if ($data->{$_} =~ /^req\.params\.(.+?)\.match\(\$(\d+)\)$/) {
                    my $param_target = $1;
                    my $match_target = $2;
                    if ($data->{'__req.params.'.$param_target} and ref $data->{'__req.params.'.$param_target}->[0] eq 'Regexp' and $match_target-1 > -1) {
                        # параметр описан регуляркой
                        $desc->{rew}->{param}->{$i} = sub {
                            $_[0]->{params}->{$param_target}->[$match_target] || '';
                        };
                    } else {
                        # ссылка на сегмент, который не был описан или был описан не регекспом
                        croak __PACKAGE__.": found error in describe '$_ = ".$data->{$_}."'";
                        %$desc = ();
                        last;
                    }                    
                } else {
                    # simple value for param
                    my $val = $data->{$_};
                    $desc->{rew}->{param}->{$i} = $val;
                }
            }
        }
        
        if (keys %$desc) {
        	# set default
        	$desc->{req}->{segments_others} = 0 unless defined $desc->{req}->{segments_others}; 
        	$desc->{req}->{params_others} ||= 1; 
        	
        	$desc->{rew}->{segments_others} = 0 unless defined $desc->{rew}->{segments_others};
        	$desc->{rew}->{params_others} ||=1;
        	
        	# chek root
        	$desc->{req}->{segment}->[0] ||= '';
        	$desc->{rew}->{segment}->[0] ||= '';
        	
        	# для варнигов
        	$desc->{rew}->{section} = $rule;
        	
        	# по умолчанию нет описаний параметров
        	$desc->{req}->{param} ||= {};
        	
        	# наличие нескольких деревьев в такой логике всегда оправдано больше, чем делать одно большое
	        my $segment_target = __make_segments_tree($self->{segments_tree}, $desc->{req});
	        if ($segment_target) {
    	        my $rewrite_target = __make_params_tree($self->{params_tree}->{"$segment_target"} ||= {}, $desc->{req});
	            if ($rewrite_target) {
	                __make_rewrite_rules($self->{rewrite_rules}->{"$rewrite_target"} ||= {}, $desc->{rew});
	            }
	        }
        };
    }
    
    if ($self->{segments_tree}->{segments_others}) {
        # чтобы не тратить потом время на сортировку ключей для uri без определённой глубины
        @{$self->{segments_tree}->{segments_others}->{depths}} = sort {$b <=> $a} @{$self->{segments_tree}->{segments_others}->{depths}};
    }
    
    #$DB::signal = 1;
    
    $self->{modified} = $modified;
    $self->{has_rule} = keys %{$self->{segments_tree}} ? 1 : 0;
    
    return;
}

sub __make_segments_tree {
	my $tree = shift;
	my $segments  = shift;
	
	$tree = $tree->{$segments->{segments_others} ? 'segments_others' : 'segments'} ||= {};
	my $depth = $#{$segments->{segment}};
	
	# чтобы не тратить потом время на сортировку ключей для uri без определённой глубины
	if ($segments->{segments_others}) {
	   $tree->{depths} ||= [];
	   push @{$tree->{depths}}, $depth;
	}  
	
	# глубина поиска имеет значение только при первом выборе саб-дерева
	$tree = $tree->{uri_depth}->{$depth} ||= {}; 
    
    # рекурсивно
    $tree = __add_segments_tree($tree, $segments->{segment});
        
    return $tree;
}

sub __add_segments_tree {
    my $tree        = shift;
    my $segments    = shift;
    
    # текущая глубина массива сегментов
    my $cd = $#$segments;
    # если нет более сегментов - возвращаем участок дерева
    return $tree if $cd == -1;
        
    my $segment = shift @$segments;
    
    my $ref = ref $segment;
    if (defined $segment and not $ref) {
        # exactly match     
        $tree = __add_segments_tree($tree->{exactly}->{$segment}  ||= {}, $segments);
    } elsif ($ref eq 'Regexp') {
        # re
        $tree->{re} ||= [];
        my $sub_tree = {};
        my $ret = __add_segments_tree($sub_tree, $segments);
        push @{$tree->{re}}, [$segment, $sub_tree];
        $tree = $ret;
    } elsif (not $ref) {
        # any
        $tree = __add_segments_tree($tree->{any} ||= {}, $segments);
    } else {
        carp "I don't know what I can do with segment $segment";
        return;
    }
    
    return $tree;
}

sub __make_params_tree {
    my $tree        = shift;
    my $params      = shift;
    
    if ($params->{params_others}) {
        $tree = $tree->{params_others} ||= {};
    } elsif (keys %{$params->{param}}) {
        $tree = $tree->{params} ||= {};
    } else {
        $tree = $tree->{without_params} ||= {};
    }

    $tree = __add_params_tree($tree, [sort keys %{$params->{param}}], $params->{param});
    
    return $tree;
}

sub __add_params_tree {
    my $tree         = shift;
    my $names_params = shift;
    my $hash         = shift;
    
    return $tree unless defined $names_params->[0];  
    
    my $p_name = shift @$names_params;
    my $p_val  = delete $hash->{$p_name};
    my $ref    = ref $p_val;
    unless ($ref) {
        # exactly match
        $tree = __add_params_tree($tree->{exactly}->{$p_name.'&'.$p_val} ||= {}, $names_params, $hash);
    } elsif ($ref eq 'Regexp') {
        # re
        $tree->{re}->{$p_name} ||= [];
        my $sub_tree = {};
        my $ret = __add_params_tree($sub_tree, $names_params, $hash);
        push @{$tree->{re}->{$p_name}}, [$p_val, keys %$sub_tree ? $sub_tree : undef];
        $tree = $ret;
    } else {
        carp "I don't know what I can do with param $p_name = $p_val";
        return;        
    }
    
    return $tree;
}

sub __make_rewrite_rules {
    my $token    = shift;
    my $rew_rule = shift;
    
    carp "'".$rew_rule->{section}."' override some rule" if $token->{_sub};
    
    $token->{_sub} = sub {
        $DB::signal = 1;
        my $url   = shift;
        my $found = shift;

        my @rew_segments = map {ref $_ eq 'CODE' ? $_->($found) : $_} @{$rew_rule->{segment}};
        if ($rew_rule->{segments_others}) {
            push @rew_segments, @{$rew_rule->{segments_others}};
        }

        my @param = ();
        if ($rew_rule->{params_others}) {
           push @param, @{$rew_rule->{params_others}}
        }
        if ($rew_rule->{param}) {
            for (keys %{$rew_rule->{param}}) {
                push @param, $_, ref $rew_rule->{param}->{$_} eq 'CODE' ? $rew_rule->{param}->{$_}->($found) : $rew_rule->{param}->{$_}   
            }
        }

        my $ret = URI->new;
        $ret->path_segments(@rew_segments);
        $ret->query_form(@param) if @param;

        return wantarray ? ($ret, $rew_rule->{section}) : $ret;
    };
    
    return;
}

sub _make_rewrite {
    my $self = shift;
    my $env  = shift;
    
    my $uri = URI->new($env->{REQUEST_URI});
    
    #my @segment = map {length $_ ? $_ : '/'} $uri->path_segments;
    #shift @segment;# TODO (? remove this)
    
    my @segment = $uri->path_segments;
    shift @segment;
    my $depth = $#segment;
    
    my @find = ();    
    my $segments_tree; my $segment_others;
    if ($self->{segments_tree}->{segments} and $self->{segments_tree}->{segments}->{uri_depth}->{$depth}) {
       $segments_tree = $self->{segments_tree}->{segments}->{uri_depth}->{$depth};
    } 
#    elsif ($self->{segments_tree}->{segments_others}) {
#        my $i = 0;
#        my @cand = @{$self->{segments_tree}->{segments_others}->{depths}};
#        for (@cand) {
#            if ($depth >= $_) {                
#                $segment_others = \@cand[$i..$#cand];
#                last;
#            }
#            $i++;
#        }
#    }

    # если нет реврайтов для данной глубины
    return if (not $segments_tree and not $segment_others);
    
    my ($params_key, $segments_find) = __search_from_segments_fix_depth([@segment], $segments_tree);
    return unless $params_key;
    
    
    1;
        
    
        
#    # не найдено дерево для данного числа сегментов
#    my $tree = $self->{rules}->{depth}->{scalar @segment}; 
#    return unless $tree; 
#    
#    # собёрм параметры в хэш
#    my $params = {};
#    for ($uri->query_param) {
#        my @param = $uri->query_param($_);
#        $params->{$_} = [@param];
#    }
#    
#    my $rewrite_url = __make_rewrite($tree, $params, @segment);
#    
#    if ($rewrite_url) {
#        # TODO: check default (path can't be null)
#        $env->{REQUEST_URI}     = "$rewrite_url";
#        $env->{PATH_INFO}       = $rewrite_url->path;
#        $env->{QUERY_STRING}    = $rewrite_url->query || '';
#        carp __PACKAGE__.": rewrite '$uri' to '$rewrite_url'" if $self->debug;
#    } elsif ($self->debug) {
#        carp __PACKAGE__.": not found rewrite rule fot '$uri'";
#    }
    
    return;
}

sub __search_from_segments_fix_depth {
    my $segments        = shift;
    my $segments_tree   = shift;   
    my $find            = shift || {};
    my $i               = shift;
    $i = -1 unless defined $i;
    $i++;
    
    # найден ключь матча
    return $segments_tree if ($segments_tree and not keys %$segments_tree and not defined $segments->[0]); 
    
    # не подошла ветка
    return unless ($segments_tree and defined $segments->[0]);
    
    my $key = undef;
    
    my $segment = shift @$segments; 
    if ($segments_tree->{exactly} and $segments_tree->{exactly}->{$segment}) {
        $key = __search_from_segments_fix_depth($segments, $segments_tree->{exactly}->{$segment}, $find, $i);
        $find->{$i} = [$segment] if $key;
    }
    
    if (not $key and $segments_tree->{re}) {
        for (@{$segments_tree->{re}}) {
            my @match = $segment =~ $_->[0];
            if (@match) {
                $key = __search_from_segments_fix_depth($segments, $_->[1], $find, $i);
                if ($key) {
                    $find->{$i} = [$segment, @match];
                    last;
                }
            }
        }
    }
    
    if (not $key and $segments_tree->{any}) {
        $key = __search_from_segments_fix_depth($segments, $segments_tree->{any}, $find, $i);
        $find->{$i} = [$segment] if $key;
    }
    
    return $key ? ($key, $find) : undef;
}


#sub __make_rewrite {
#    my ($tree, $params, @segment) = @_;
#    
#    
#    return;
#}

1;
__END__
# description /foo/123456Jhon/bar/?baz=2011

[my rewrite bla-bla /foo/123456Jhon/bar/?baz=2011trach&daz=1 => /foo/123456/Jhon/bar/?baz=2011&daz=1 ]
req.segments[0]     = foo
req.segments[1]     =~ /^(\d{0,6})(\w+)$/
req.segments.others = 1
req.params.baz      =~ /^(\d{4})/

rew.segments[0]     = foo
rew.segments[1]     = req.segments[1].match($1)
rew.segments[2]     = req.segments[1].match($2)
rew.segments.others = 1
rew.params.baz      = req.params.baz.match($1)  
rew.params.others   = 1