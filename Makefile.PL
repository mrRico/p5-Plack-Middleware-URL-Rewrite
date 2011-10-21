use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'Plack::Middleware::URL::Rewrite',
    VERSION_FROM      => 'lib/Plack/Middleware/URL/Rewrite.pm',
    PREREQ_PM         => {
    	'URI::QueryParam'          => 0,
    	'Config::Mini::WithRegexp' => 0,
    	'Plack::Middleware'        => 0
    }
);
