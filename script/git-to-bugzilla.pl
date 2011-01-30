#!/usr/bin/env perl
#
#
use strict;
use warnings;
use Carp;
use Config::Any;
use Data::Dump;
use File::Slurp;
use FindBin;
use Getopt::Long;
use Git::Repository;

use lib "$FindBin::Bin/../lib";
use WWW::Bugzilla;

my $verbose;
my $debug;

# ------------------------------------------------------------------------
sub update_bugzilla {
    my $cfg  = shift;
    my $info = shift;
    my $set  = shift;

    my $bz = WWW::Bugzilla->new(
        server     => $cfg->{bugzilla}{server},
        email      => $cfg->{bugzilla}{user},
        password   => $cfg->{bugzilla}{pass},
        bug_number => $set->{bug}
    ) || croak "Cannot open bz - $!";

    my $header = sprintf( "Git commit: %s/commitdiff/%s\n", $cfg->{gitweb}, $info->{rev} );
    if ( scalar( @{ $info->{diff} } ) > 50 ) {

        # big diff - we skip the diff
        $bz->additional_comments(
            join( "\n", $header, @{ $info->{info} }, '', @{ $info->{log} }, '----', @{ $info->{diffstat} } ) );
    }
    else {

        # otherwise we do the whole thing
        $bz->additional_comments( join( "\n", $header, @{ $info->{all} } ) );
    }

    $bz->change_status("fixed")  if ( $set->{action} =~ /fixes/ );
    $bz->change_status("closed") if ( $set->{action} =~ /closes/ );

    $bz->commit;

    printf( "[%d] %s %s [%s]\n", $set->{bug}, $info->{rev}, $info->{log}[0], $set->{action} );
}

# ------------------------------------------------------------------------
sub find_bugzilla_references {
    my $info = shift;
    my $cfg  = shift;

    my @results;
    my $action = '';
    my $bugid;
    foreach my $line ( @{ $info->{log} } ) {
        $line = lc($line);
        if ( $line =~ /(closes|fixes|references):?\s*(?:bug(?:zilla)?)?\s*\#?(\d+)/ ) {
            $action = $1;
            $bugid  = $2;
        }
        elsif ( $line =~ /\b(?:bug(?:zilla)?)\s*\#?(\d+)/ ) {
            $action = 'references';
            $bugid  = $1;
        }
        else {
            next;
        }

        # remap actions

        push( @results, { bug => $bugid, action => $action } );
        ##printf( "%s\n\taction = %s bugid = %s\n", $info->{rev}, $action, $bugid );
    }
    return @results;
}

# ------------------------------------------------------------------------

sub git_commit_info {
    my $git = shift;
    my $rev = shift;

    my @lines = $git->run( 'show', '-M', '-C', '--patch-with-stat', '--pretty=fuller', $rev );

    my $info = {
        rev      => $rev,
        info     => [],
        log      => [],
        diffstat => [],
        diff     => [],
        all      => [@lines],    # deliberate copy
    };

    while ( my $line = shift @lines ) {
        last if ( $line =~ /^$/ );
        push( @{ $info->{info} }, $line );
    }

    while ( my $line = shift @lines ) {
        last if ( $line =~ /^---\s*$/ );
        push( @{ $info->{log} }, $line );
    }

    while ( my $line = shift @lines ) {
        last if ( $line =~ /^$/ );
        push( @{ $info->{diffstat} }, $line );
    }

    # all the rest
    $info->{diff} = \@lines;

    return $info;
}

# ------------------------------------------------------------------------

sub walk_git_commits {
    my $git = shift;
    my $cfg = shift;

    my $lastrev = $git->run( 'rev-parse', $cfg->{lastref} );
    my $headrev = $git->run( 'rev-parse', $cfg->{branch_head} );

    return if ( $lastrev eq $headrev );

    my @revs = $git->run( 'rev-list', '--topo-order', '--no-merges', ( $lastrev . '..' . $headrev ) );

    foreach my $rev ( reverse(@revs) ) {
        my $info = git_commit_info( $git, $rev );

        #ddx($info);
        #dd( $info->{info}, $info->{log}[0] );
        my @sets = find_bugzilla_references( $info, $cfg );
        foreach my $set (@sets) {
            update_bugzilla( $cfg, $info, $set );
        }
    }
    return $headrev;
}

# ------------------------------------------------------------------------

# main
{
    my $config;

    GetOptions(
        'config=s' => \$config,
        'debug!'   => \$debug,
        'verbose!' => \$verbose,
    ) or die "Incorrect options";
    die "No config file given\n" unless ( $config and -f $config );
    my $cfg = ( values( %{ Config::Any->load_files( { files => [$config], use_ext => 1 } )->[0] } ) )[0];

    die "No git_dir specified\n" unless ( $cfg->{git_dir} );
    $cfg->{lasttag} ||= $cfg->{git_dir} . '/refs/tags/BugzillaDone';
    $cfg->{branch_head} ||= 'HEAD';

    $cfg->{lastref} = -f $cfg->{lasttag} ? read_file( $cfg->{lasttag} ) : 'HEAD';
    chomp( $cfg->{lastref} );

    my $git = Git::Repository->new( git_dir => $cfg->{git_dir} ) || die "No valid git repo\n";

    my $newlast = walk_git_commits( $git, $cfg );
    if ($newlast) {
        write_file( $cfg->{lasttag}, $newlast );
    }
}
