use Test::More;
use File::Spec;
use Cwd 'abs_path';

    pass('*' x 10);
    pass('Plack::Middleware::URL::Rewrite');
    
    # use
    use_ok('Plack::Middleware::URL::Rewrite');
    can_ok('Plack::Middleware::URL::Rewrite','new');
    
    # create instance
    my $r = Plack::Middleware::URL::Rewrite->new(conf => File::Spec->catfile(sub {local @_ = File::Spec->splitpath(abs_path(__FILE__)); $_[$#_] = 'rewrite.mini'; @_}->()));
    isa_ok($r, 'Plack::Middleware::URL::Rewrite');
    isa_ok($r, 'Plack::Middleware');
    
    can_ok($r,'_init');
    $r->_init;
    can_ok($r,'_make_rewrite');    
    
    my $rew_ex = {
        #'/foo/123/ann/bann/zzed?baz=2011' => '/foo/12/3?baz=2011',
        #'/foo/123/ann/bann/zzed?baz=2011&foo=bar' => '/foo/12/3?foo=bar&baz=2011',
        #'/foo?mode=some&bar=baz' => '/bar/mode/some?bar=baz',
        '/foo/baz/bar?mode=submode&any=12' => '/bar/was_param/submode/baz/bar',
        #'/foo/baz/bar?mode=submode' => '/bar/mode/submode/baz/bar'
    };
    
    for (keys %$rew_ex) {
        my $env = {REQUEST_URI => $_};
        $r->_make_rewrite($env);
        is($env->{REQUEST_URI}, $rew_ex->{$_}, $_.' to '.$rew_ex->{$_});
    }
    
    
    pass('*' x 10);
    print "\n";
    done_testing;
        