#!/usr/bin/perl
#Copyright 2007-2009, Bastian Angerstein.  All rights reserved.  This program is free
#software; you can redistribute it and/or modify it under the same terms as
#PERL itself.
package Net::Ping::Network;

# infrastructure requirements
use strict;
use warnings;
use 5.008008;
our $VERSION = '1.62';

use threads;
use threads::shared;
use Thread::Queue;

require Exporter;
use base qw ( Exporter );

our @EXPORT_OK = qw ( new &doping calchosts listAllHost results );
our %EXPORT_TAGS = ( all => [ qw ( new doping calchosts listAllHost results ) ],
                     min => [ qw (new doping results )]   );

use Config;
$Config{useithreads} or die "Recompile Perl with threads to run this program.\n";

use Net::Ping::External qw(ping);

our %REGISTRY;
my $verbose = 0;

my $DataQueue = Thread::Queue->new; # a shared Queue Object
my %results : shared;     # a shared $hash
my %process_time : shared; # a shared $hash


sub new {

    # this is the constructor of net::ping::networks.
    my $class = shift; # read the Name of our Class
    my $net = undef;   # initialize a var for our net
    my $mask = undef;  # initialize a var for our mask
    my @hostlist = ();  # initialize an array to contain a list of user given hosts

    if (ref $_[0]) {   # if we where called with a ref, we expect this to be an ref of array containing ips
        @hostlist = @{$_[0]}; # a user specified list of all hosts to ping given as reference to an array
    } else { # if we don�t get a ref, we expect regular usage with a given netwrok and a mask
        $net = shift;
        $mask = shift;
    }

    my $timeout = shift; #expect an optional timeout in seconds
    $timeout = defined($timeout)?$timeout:3;   # no timeout specified? default to 3
    my $retries = shift;
    $retries = defined($retries)?$retries:3;  # no retries specified? default to 3
    my $threads = shift;
    $threads = defined($threads)?$threads:10; #no amount of threads specified? default to 10
    my $bsize = shift;
    $bsize = defined($bsize)?$bsize:56; #no amount of threads specified? default to 56 + icmpheader = 64
    
    my ($self) = {       # Building our Objecthash
        NET => $net, # Base Adress
        MASK => $mask,    # Netmask
        TIMEOUT => $timeout, #Max. Timeout ins seconds
        RETRIES => $retries, #Max. Retries
        TC => $threads, #Max. Threads
        SIZE => $bsize, #Size of ICMP Payload
        TJ => 0, #Joinable Threads
        TR => 0, #Running Threads
        #VERBOSE => 0, # Debugging
        HOSTS => 0,   # Number of Hosts
        SUMOFHOSTS => 0,  # Sum of all Hosts
        RESULTS => 0,
        CONF_PING => \&conf_ping, # A Code-Ref need for threading
    };

    if ( @hostlist ){ #if we received a list of hosts from the user
      @{ $self->{ 'HOSTLIST' } } = @hostlist;
    } else {
      @{ $self->{ 'HOSTLIST' } } = ();  
    }
    $self->{ 'ALLHOSTS' } = (); # for a autogenerated list of all hosts to ping

    $REGISTRY{$self} = $self;
    bless ($self, $class);
    return ($self);
}

################################################################################

sub verbose { # Only a poor Debugging Sub
  my @output = shift;
  print @output if ( $verbose );
  return (1); 
}

################################################################################

sub setHosts{ # Hand a List of Hosts by Yourself.
  my ($self) = shift;
  @{$self->{'HOSTLIST'}} = @_;
  print @_;
  return ($self);
}

################################################################################
sub calchosts { # Berechnet anhand der Maske die Anzahl der M�glichen Hosts in einem Netz.
    #Die Broadcastadress ist kein m�glicher Hosts.
    #Die Netzbasisadresse wird ebenso entfernt.
   my ($self) = shift;
   my $lmask;  #get the mask
   my $pO2=0;
   if ( ref ($self) ) { # Am I a Ref?
     if ( ${ $self->{'HOSTLIST'} }[0]  ) {  # if there is a userdefined list of hosts, return the amount of hosts found
        return  scalar ( @{ $self->{'HOSTLIST'} } ); 
     }
     $lmask = $self->{MASK};
   } elsif ($self) { # Am I a true interger value?
      if ($self >= 0 && $self <= 32) { # is mask a valif value?
        $lmask = $self; # copy mask for better readability
      } else {
        die "No useable netmask found: $self is not a netmask.\n";
      }
   } else { # Is no parameter given?
      print STDERR "A parameter is missing.";
   }
    
    # Implementing RFC3021 /31 Net has 2 Hosts
    if ($lmask == 31) {
      $pO2=2;
    } elsif ($lmask == 32) {
      $pO2=1;
    } else { # if no fancy ip stuff is going on 
        my $bits = 32 - $lmask; # Calculate the amount of bits in the host section of the mask
        $pO2 = (2 ** $bits) -2; # substract net and broadcast address
        if ($pO2 < 1) {
          $pO2=1;
        }
    }
    if (ref $self ){ # how should I return the data
      $self->{'HOSTS'} = $pO2; # adding it to the object
    } else {
      return $pO2; # returning it as a integer value
    }
}

################################################################################
sub listAllHost { # List all possible host of a net or all host received from user.
	#  expects a network address and a mask
	# or expects that net::ping::networks has received a list of hosts
    my ($self) = shift;
    
    my $net = undef; #Net like 127.0.0.0
    my $mask = undef; #Mask like 24.

    if ( ref ($self) ) { # Am I a ref?
      if ( ${ $self->{'HOSTLIST'} }[0]  ) {
          return wantarray ? @{ $self->{'HOSTLIST'} }: join(" ",@{ $self->{'HOSTLIST'} }); # Retrun an Array in list context, return a whitespace seperated string in scalar context
      }
      $mask = $self->{'MASK'}; # configure the object 
      $net = $self->{'NET'}; # configure the object
    } else { # no ref? then calculate all possiblie hosts by given mask and net
      $net = $self; 
      $mask = shift;
    }
   
    die "Missing parameters listAllHost\n" unless ( defined $net && defined $mask);

    my @allHosts; # an Array for the list of all hosts
    my @net_p = split(/\./, $net ); # Split the IP

    my $sumOfHosts = calchosts( $mask ); #Calculate the amount of possible hosts.

    if ( ref ($self) ) { # if we have a object
      $self->{'SUMOFHOSTS'} = $sumOfHosts; # add another field
    }

    my $i = 1; #Counter/Itterator
    while ($i <= $sumOfHosts ) { # Solange wie Counter kleiner Anzahl der Hosts ist
        $net_p[3]++;            # Inkrementiere letzten Abschnitt der IP
        if ($net_p[3] > 255){   # Wenn der letzte Abschnitt nun eine h�hreren Wert hat als 255
            $net_p[2]++;        # Inkrementiere den vorletzten Abschitt.
            $net_p[3] = 0;      # und setze den vierten Abschnitt auf 0
        }
        if ($net_p[2] > 255){   # Wenn der dritte Abschnitt nun gr��er ist als 255
            $net_p[1]++;        # inkrementiere den zweiten Abschnitten
            $net_p[2] = 0;      # und setze den dritte Abschnitt auf 0
        }
        if ($net_p[1] > 255){   # Wenn der zweite Abschnitt...
            $net_p[0]++;
            $net_p[1] = 0;
        }
        if ($net_p[0] > 255){   # Wenn der erste Abschnitt gr��er als 255 ist
            die "Out of IP-Range"; # Sterbe und gebe Out of IP-Range.
        }
        my $ip = join(".",@net_p); #f�ge die Abschnitte zu einem String zusammen.
        push (@allHosts,$ip);   # Sammle alle Strings
        $i++;                   #inkrementiere Counter
    } #while

    if ( ref ($self) ) {
      $self->{'ALLHOSTS'} = @allHosts;
    }

    return wantarray ? @allHosts : join(" ",@allHosts); #if wantarray 1 then @
                                                   #if wantarray 0 dann $
}

################################################################################
sub conf_ping {
    # Thread-Sub which does the pinging
    my ($self) = shift;
    use Time::HiRes qw(gettimeofday tv_interval);

    verbose ( $self . " thread\n" );
    my $thr = threads->self; #Der thread selbst
    my $tid = $thr->tid; # Die ID des Threads

    verbose "$tid has started.\n"; # Thread-ID Status mit.

    while ( my $host = $DataQueue->dequeue_nb ) { # nonblocking dequeuen of an address.
        verbose( "$tid is working.\n" ); #Debugging
        my $t0 = [gettimeofday];
        if( ping ( host => "$host",  count => $self->{RETRIES}, timeout => $self->{TIMEOUT}, size => $self->{SIZE} )){ # Den Host pingen
            my $t1 = [gettimeofday];
            verbose ("$host is alive.\n");
            $results{$host}  = 1;              # Good
            $process_time{$host} = tv_interval $t0, $t1;
        } else {
            my $t1 = [gettimeofday];
            verbose ( "$host is unreachable!\n" );
            $results{$host}  = 0;           #Bad
            $process_time{$host} = tv_interval $t0, $t1;
        }
         $thr->yield;                          # Be gentle
    }
    verbose ("$tid is done.\n");

    return(1);
}

################################################################################

sub doping {
   # This Subroutine does the Pings.
    my ($self) = shift;
    %results = ();
    %process_time = ();
    verbose ( @{ $self->{ 'HOSTLIST' } } );

    if ( @{ $self->{ 'HOSTLIST' } } ){ # If User provides a List of Hosts
         $DataQueue->enqueue ( @{ $self->{ 'HOSTLIST' } } );
    } else {
      $DataQueue->enqueue ( listAllHost($self->{'NET'}, $self->{'MASK'}) ); # Build and Enqueue a list of hosts to ping.
    }
    verbose ( "Main: StartingUp" . $self->{'TC'} . "Threads.\n" );
    for (my $i=0; $i < $self->{'TC'}; $i++){
      $self->{ $i } = 0;
      $self->{ $i } = threads->new({'context' => 'list'}, $self->{CONF_PING}, $self); ##############
      select(undef, undef, undef, 0.02);   # take a napp
      if ($self->{ $i }->error) {
        print "Main: Error:" . $self->{ $i }->error . "\n";
      }
         verbose ("Main: $i Threads have been initialized.\n");
    }
    verbose ( "Main: StartUp-Sequence of" . $self->{'TC'} . "Threads completed.\n");

    while ( threads->list(threads::running) or threads->list(threads::joinable ) ) {
         my @joinable = threads->list(threads::joinable); #Check for finished Threads
         $self->{'TJ'} = scalar (@joinable);                     #Get Amount of Finished Threads
         $self->{'TR'} = threads->list(threads::running);        #Check for running Threads
         verbose ( "Main: Queued Items = " . $DataQueue->pending . ".\nJoinable Threads = " . $self->{'TJ'} . " Running Threads = " . $self->{'TR'} . ".\n"); #Give a Process Status
         foreach my $t (@joinable) {
            $t->join;
         }
         select(undef, undef, undef, 0.02);     # be gentle
    }
    verbose ( %results );
    $self->{RESULTS} = \%results;
    $self->{MSEC} = \%process_time;
    return (\%results, \%process_time);
}

################################################################################
sub results {
    my ($self) = shift;
    return $self->{RESULTS};
}

sub process_time {
    my ($self) = shift;
    return $self->{MSEC};
}
1;

=head1 NAME
Net::Ping::Network  - A modul to ICMP-request nodes in a network (or list) very fast

=head1 SYNOPSIS

Import Net-Ping-Network and use the original Interface.
Simply give a network address and a mask to the constructor new().

    use Net::Ping::Network;
    my $net = Net::Ping::Network->new("127.0.0.0", 29);


Optionally the timeout in seconds (3), the amount of retries (3),
the number of threads utilized (10) and the size in byte (56) of icmp-load can be specified.

    my $net = Net::Ping::Network->new("127.0.0.0", 29, $timeout, $retries, $threads, $size);


To ping the hosts in the network use the doping() methode of your Net::Ping::Network methode.
When Net::Ping::Network is done, you can get the results as hashref using the methode results().
 
    $net->doping();
    my $results = $net->results();
 
    #Since Version 1.62 you can simply    
    my ($results,$process_time = $net->doping();

The hashkey of $results hash_ref is the ip, the value is 1 for reachable, 0 for unreachable.
The hashkey of $process_time is the ip, the value is a value in microseconds needed to process the ping.
(It is the roundtrip-time of the ping. If no response is received its a value near the given timeout.)

The hash is not sorted in anyway, to sort a hash is useless.
If you need sorted results try this:

1. get the Keys from the returned hashref (ips).

    my @unsorted_keys = keys %$results;

2. using a sort over the packed data. This is much fast then sort by every field.

    my @keys = sort { # sort list of ips accending
     pack('C4' => $a =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/)
     cmp pack('C4' => $b =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) } @unsorted_keys;


    foreach my $key ( @keys ) {
        print "$key" . " is ";
        if ( $$results{"$key"} ) {
          print  "alive.\n";
        } else {
          print "unreachable!\n";
        }
    }

A list of all hosts to ping, can be gathered from the methode listAllHost()

    my  @all = $net->listAllHost();
    my $list = $net->listAllHost();

In list context listAllHost returns an array containing all hosts to ping.
In scalar context this methode returns a whitespace separeted string of all IPs.

If you need the number of Host for a given netmask use
  my $x = $net->calchosts();
or
  my $y = calchost(22);

calchosts() calculates the max. number of host in a network with the given mask.
The broadcast address is not a possible host, the network base address ist not a possible host.



=head2 DESCRIPTION


The existing ping moduls are slow and can only handle one ping at a time.
Net::Ping::Networks (Net::Ping::Multi) can handle even large ip ranges and entire networks.
Depending of your computing power and memory you can scan a class c network in less then 5 seconds.

On a normal desktop computer and without any further tuning, one should be able to manage 2500-3000 ips in less then 5 minutes.

Threads are utilised to boost performace. Threads feel a still a little bit beta today.

=head2 Methodes

=over 1

=item C<new()>

creates a new Net::Ping::Network instance. Needs a network base address and netmask or an array of ips to ping.
If a network base address and a mask is supplied, Net::Ping::Networks will build a List of all host-ips in the net
automaticaly.

C<< $n = Net::Ping::Network->new("127.0.0.0", 29, [$timeout, $retries, $threads, $size]); >>


=item C<listAllHost()>

depending on the context it returns a list containig all possible Hosts in the network or a space seperated string.


=item C<doping()>

executes the configured ping utilising the given parameters.
As lower the amount auf pings per threads is, as faster the methode will return.

=item C<calchosts()>

Calculates the amount of possible hosts for a Netmask, value between 0 and 32 is expected.
Network-Address and Broadcast is removed, but a /32 has 1 Address. 

=item C<results()>

Returns a Hashref of the Results. Keys are IPs, the Values are returncodes (0 for bad or 1 for ok).

=item C<process_time()>

Returns a Hashref of the per Host Process Time (PIND ROUNDTRIPTIME). Keys are the Host-IPs. 

=back

=head1 COPYRIGHT

Copyright 2007-2009, Bastian Angerstein.  All rights reserved.  This program is free
software; you can redistribute it and/or modify it under the same terms as
PERL itself.

=head1 AVAILABILITY

=head1 CAVEATS

Threads are cpu and memory intensive and feel still beta. Have an extra eye on memory leaks.
Net::Ping::Networks is a quick and dirty but easy to read and understand implementation.
Documentation is in the Code.

Also it "could" lead into trouble to use a multithreaded modul in a multithreaded environment.

=head1 AUTHOR

Bastian Angerstein - L<http://www.cul.de/>

=head1 SEE ALSO

L<net::ping>, L<net::ping::external>

=cut

