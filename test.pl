#!/usr/bin/perl
use strict;
use warnings; 

use Plack::Middleware::URL::Rewrite; 

my $r = Plack::Middleware::URL::Rewrite->new(conf=>'kill.mini');
$r->_init;
$r->_make_rewrite({REQUEST_URI => '/foo/123/ann/bann/zzed'});




exit;