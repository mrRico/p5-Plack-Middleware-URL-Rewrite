#!/usr/bin/perl
use strict;
use warnings; 

use Plack::Middleware::URL::Rewrite; 

my $r = Plack::Middleware::URL::Rewrite->new(conf=>'kill.mini', debug => 1);
$r->_init;
my $env = {REQUEST_URI => '/foo/123/ann/bann/zzed?baz=2011'};
$r->_make_rewrite($env);

1;


exit;