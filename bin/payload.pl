#!  /usr/bin/perl -w

# <TODO> 
# Initial holddown
# Suppress extra newlines 
# Comment
# Document
# Test: Bidir
#</TOOD>

use strict;
no strict 'refs';
use FindBin qw($Bin);
use lib "$Bin/..";
use Baka::ScriptUtils (qw(berror bdie bruncmd bopen_log bmsg bwant_stderr bask bwarn));;
use File::Basename;
use Getopt::Long;
use Net::Pcap;
use Net::IP;
use Socket;
use NetPacket qw(htonl htons);
use NetPacket::Ethernet;
use NetPacket::IP;
use NetPacket::TCP;

use NetPacket::UDP;
use FileHandle;
use Data::Dumper;

sub make_association($$$$$ );
sub destroy_assoc($$ );
sub ip2i($ );
sub close_file($$$ );
sub get_other_direction($ );

use constant
{
  ETHERTYPE_IP		=> 2048,	# net/ethernet.h
  IPPROTO_TCP		=> 6,
  IPPROTO_UDP		=> 17,
  TIMEOUT_2MSL		=> 240.0, 	# The comparison is with a floating point number.
#  TIMEOUT_2MSL		=> 1.0, 	# The comparison is with a floating point number.
};

use constant
{
  DIRECTION_FROM_SOURCE	=> 0,
  DIRECTION_TO_SOURCE	=> 1,
};

our $progname = basename($0);

my $progbase = $progname;
$progbase =~ s/\.pl$//;
my $live_capture_done = 0;

my @required_args = ( "list-devs", "live", "file" );

my $USAGE = "Usage: $progname --list-devs | --live=DEV | --file=DMPFILE [--debug] [--filter=FILTER] [--log-file=FILE] [--netmask=NETMASK] [--[no-]optimize] [--snaplen=LEN] [--[no]-promisc] [--to-ms=TIMEOUT] [--bidir!] [--dir=DIRECTORY] [--[no-]permit-misordered] [--[no-]stats] [--[no-]broadcast] [--[no-]standard-filter] [--[no-]hostnames]\n";

my(%OPTIONS);
Getopt::Long::Configure("bundling", "no_ignore_case", "no_auto_abbrev", "no_getopt_compat");
GetOptions(\%OPTIONS, 'debug|d+', 'list-devs', 'live=s', 'filter=s', 'file=s', 'log-file=s', 'snaplen=i', 'verbose|v', 'promisc!', 'netmask=s', 'optimize!', 'to-ms=i', 'permit-misordered!', 'bidir!', 'stats!', 'broadcast!', 'standard-filter!', 'hostnames!', 'dir=s', 'help|?') || die $USAGE;
die $USAGE if ($OPTIONS{'help'});
die $USAGE if (@ARGV);

my $required_cmd_cnt = grep { my $option = $_; grep { $option eq $_; } keys %OPTIONS } @required_args;

die "$USAGE" if ($required_cmd_cnt != 1);

my $snaplen = $OPTIONS{'snaplen'} // 1024;
my $promisc = $OPTIONS{'promisc'} // 1;
my $to_ms = $OPTIONS{'to-ms'} // 0;
my $filter_str = $OPTIONS{'filter'} // "";
my $netmask_str = $OPTIONS{'netmask'} // "0.0.0.0";
my $optimize = $OPTIONS{'optimize'} // 0;
my $bidir = $OPTIONS{'bidir'} // 1;
my $dir = $OPTIONS{'dir'} // "/tmp/payload.d";
my $permit_misordered = $OPTIONS{'permit_misordered'} // 1;
my $stats = $OPTIONS{'stats'} // 0;
my $broadcast = $OPTIONS{'broadcast'} // 0;
my $debug = $OPTIONS{'debug'} // 0;
my $standard_filter = $OPTIONS{'standard-filter'} // 1;
my $hostnames = $OPTIONS{'hostnames'} // 1;

my $log_file = $OPTIONS{'log-file'} // "/tmp/${progbase}.$ENV{USER}";
my $log = bopen_log($log_file);
bwant_stderr(1);

my $pcap;
my $pcap_err;
if ($OPTIONS{'list-devs'})
{
  my %devinfo;
  my @devs = Net::Pcap::pcap_findalldevs(\%devinfo, \$pcap_err);

  bdie("Could not determine the list of devices: $pcap_err", $log) if ($pcap_err);

  foreach my $dev (@devs)
  {
    if (!$OPTIONS{'verbose'})
    {
      print "$dev\n";
    }
    else
    {
      print "$dev: $devinfo{$dev}\n";
    }
  }
  exit(0);
}
elsif ($OPTIONS{'live'})
{
  my $dev = $OPTIONS{'live'};

  $SIG{'INT'} = sub { $live_capture_done = 1 };

  bdie("Could not open $dev: $pcap_err", $log) if (!($pcap = Net::Pcap::pcap_open_live($dev, $snaplen, $promisc, $to_ms, \$pcap_err)));
}
elsif ($OPTIONS{'file'})
{
  my $savefile = $OPTIONS{'file'};
  bdie("Could not open savefile: $savefile: $pcap_err", $log) if (!($pcap = Net::Pcap::pcap_open_offline($savefile, \$pcap_err)));
}
else
{
  bdie("$USAGE", $log);
}

my $filter;

my $full_filter_str = "ip";
$full_filter_str .= " and not broadcast" if (!$broadcast);
$full_filter_str .= " and not ( udp or port 2049 or port 443 or port 22 or port 111 or portrange 5999-6011 )" if ($standard_filter);
$full_filter_str .= " and ( $filter_str )" if ($filter_str);

print STDERR "Filter string: $full_filter_str\n" if (($standard_filter && ($debug > 2)) || (!$standard_filter && $debug));

my $netmask = unpack("L", pack("C4", split(/\./, $netmask_str)));
bdie("Could not compile filter: " . Net::Pcap::pcap_geterr($pcap), $log) if (Net::Pcap::pcap_compile($pcap, \$filter, $full_filter_str, $optimize, $netmask) < 0);
bdie("Could not set the filter: " . Net::Pcap::pcap_geterr($pcap), $log) if (Net::Pcap::pcap_setfilter($pcap, $filter) < 0);
Net::Pcap::pcap_freecode($filter);

bdie("Could not create $dir", $log) if (bruncmd("mkdir -p $dir", $log) != 0);

my %pcap_header;
my $assoc_info = {};
my ($pkt_cnt, $misordered_cnt) = (0, 0); # Stats
my $last_pkt_time = 0.0;
my ($pcap_ret, $pkt);
while (!$live_capture_done && ($pcap_ret = Net::Pcap::pcap_next_ex($pcap, \%pcap_header, \$pkt)) == 1)
{
  $pkt_cnt++;

  # Get paket time
  my $pkt_time = $pcap_header{'tv_sec'} + $pcap_header{'tv_usec'} / 1000000.0;

  # Obtain packet.
  my $eth_obj = NetPacket::Ethernet->decode($pkt);

  # Check and update packet time (before we do any kind of filtering).
  if ($pkt_time < $last_pkt_time)
  {
    bwarn("Out of order packet! Results may be unpredictable", $log) if (!$misordered_cnt);
    $misordered_cnt++;
    next if (!$permit_misordered);
  }
  else
  {
    # NB: We only *advance* the packet time. Time stamps on misordered packets are ignored.
    $last_pkt_time = $pkt_time;
  }

  # Skip non-IP packet.
  next if (($eth_obj->{'type'}&0xffff) != ETHERTYPE_IP);

  my $ip_pkt = $eth_obj->{'data'};

  my $ip_obj = NetPacket::IP->decode($ip_pkt);

  my($src_ip, $dst_ip, $proto); # "dest"? Sheesh..
  if ($ip_obj->{'foffset'} == 0)
  {
    $src_ip = $ip_obj->{'src_ip'};
    $dst_ip = $ip_obj->{'dest_ip'};
    $proto = $ip_obj->{'proto'};
  }
  else
  {
    # <TODO> Handle frangments. Uggh.. </TODO>
    bwarn("Fragments not currently handled!", $log);
    next;
  }

  next if (($proto != IPPROTO_TCP) &&  ($proto != IPPROTO_UDP));

  my ($tcp_obj, $udp_obj, $src_port, $dst_port, $data);
  # Decode transport layer and set ports and data.
  if ($proto == IPPROTO_TCP)
  {
    $tcp_obj = NetPacket::TCP->decode($ip_obj->{'data'});
    $src_port = $tcp_obj->{'src_port'};
    $dst_port = $tcp_obj->{'dest_port'};
    $data = $tcp_obj->{'data'};
  }
  else
  {
    $udp_obj = NetPacket::TCP->decode($ip_obj->{'data'});
    $src_port = $udp_obj->{'src_port'};
    $dst_port = $udp_obj->{'dest_port'};
    $data = $udp_obj->{'data'};
  }

  my $assoc = make_association($src_ip, $dst_ip, $proto, $src_port, $dst_port);

  # Set the first_from immediately.
  my $first_from;
  if (!defined($assoc_info->{$assoc}))
  {
    print STDERR "Creating assoc: $assoc\n" if ($debug);
    $assoc_info->{$assoc}->{'first_from'} = $first_from = $src_ip;
    $assoc_info->{$assoc}->{'proto'} = $proto;
    $assoc_info->{$assoc}->{'fh'} = {};
  }
  else
  {
    $first_from = $assoc_info->{$assoc}->{'first_from'};
  }

  # Update association time.
  $assoc_info->{$assoc}->{'last_pkt_time'} = $pkt_time;
  
  # Set the direction packet.
  my $direction = ($assoc_info->{$assoc}->{'first_from'} eq $src_ip)?"@{[DIRECTION_FROM_SOURCE]}":"@{[DIRECTION_TO_SOURCE]}";

  # If this a TCP segment then check to see if the FIN is set so we can track close conditions.
  if (($proto == IPPROTO_TCP) && ($tcp_obj->{'flags'} & FIN))
  {
    print STDERR "Saw FIN: ${src_ip}:${src_port} => ${dst_ip}:${dst_port}\n" if ($debug);
    $assoc_info->{$assoc}->{'FIN'}->{$src_ip} = 1;
    close_file($assoc_info, $assoc, $direction);
  }

  my $fh;
  if ($data)
  {
    if (!defined($fh = $assoc_info->{$assoc}->{'fh'}->{$direction}))
    {
      my $filename = "";
      my ($src_hostname, $dst_hostname);

      if ($hostnames)
      {
	$src_hostname = gethostbyaddr(inet_aton($src_ip), AF_INET) || $src_ip;
	$dst_hostname = gethostbyaddr(inet_aton($dst_ip), AF_INET) || $dst_ip;
      }
      else
      {
	$src_hostname = $src_ip;
	$dst_hostname = $dst_ip;
      }

      # Make the protcol the first element of the hostname unless we're
      # using the standard filter in which case we know we're filtering out
      # all udp".

      $filename .= getprotobynumber($proto) . "-" unless ($standard_filter);

      if ($OPTIONS{'bidir'} || ($direction eq DIRECTION_FROM_SOURCE))
      {
	$filename .= "${src_hostname}:${src_port}:${dst_hostname}:${dst_port}";
      }
      else
      {
	$filename .= "${dst_hostname}:${dst_port}:${src_hostname}:${src_port}";
      }

      $filename = "${dir}/${filename}";

      bdie("Could not open $filename for writing: $!", $log) if (!($fh = FileHandle->new(">> $filename")));

      print STDERR "Opening file: $fh\n" if ($debug > 1);
      $assoc_info->{$assoc}->{'fh'}->{$direction} = $fh;
      if ($bidir)
      {
	my $other_direction = get_other_direction($direction);
	$assoc_info->{$assoc}->{'fh'}->{$other_direction} = $fh;
      }
    }
    
    if ($bidir)
    {
      my $direction_char = (($direction eq DIRECTION_FROM_SOURCE)?'>':'<');
      print $fh "\n" . ($direction_char x 6) . "\n";
    }
    print $fh $data;
  }

  # Don't save UDP "associations" as there really is no such thing (so,
  # yes, UDP's cause the data file to open close each time;
  destroy_assoc($assoc_info, $assoc) if ($proto == IPPROTO_UDP);

  # Scan the TCP associattions for those that have timed out. NB: $assoc is
  # *reused* here, so this must always be the last thing in the
  # function. Too bad we don't have try/finally.
  foreach $assoc (keys(%{$assoc_info}))
  {
    next if ($assoc_info->{$assoc}->{'proto'} != IPPROTO_TCP); # Should never be true
    if (keys(%{$assoc_info->{$assoc}->{'FIN'}}) == 2)
    {
      destroy_assoc($assoc_info, $assoc) if (($pkt_time - $assoc_info->{$assoc}->{'last_pkt_time'}) >= TIMEOUT_2MSL);
    }
  }
}

if (!$live_capture_done)
{
  if ($pcap_ret == 0)
  {
    if ($OPTIONS{'live'})
    {
      bmsg("pcap timer expired", $log);
    }
    else
    {
      berror("pcap return 0 from savefile read (should not happen): " . Net::Pcap::pcap_geterr($pcap), $log);
    }
  }
  elsif ($pcap_ret == -1)
  {
    berror("Error getting next packet: " . Net::Pcap::pcap_geterr($pcap), $log);
  }
  elsif ($pcap_ret == -2)
  {
    berror("pcap return -2 from live_capture (should not happen): " . Net::Pcap::pcap_geterr($pcap), $log) if (!$OPTIONS{'file'});
  }
}


# Destroy all remaining associations (basically to ensure that the output files are closed).
foreach my $assoc (keys(%{$assoc_info}))
{
  destroy_assoc($assoc_info, $assoc);
}

if ($stats)
{
  my $format = "%10s: %i\n";
  printf($format, "IP Packets", $pkt_cnt);
  printf($format, "Misordered", $misordered_cnt);
}

exit(0);



sub END
{
  Net::Pcap::pcap_close($pcap) if (defined($pcap));
}



sub make_association($$$$$ )
{
  my ($src_ip, $dst_ip, $proto, $src_port, $dst_port) = @_;
  my $src_first = 0;

  my $sip = ip2i($src_ip);
  my $dip = ip2i($dst_ip);
  my $sport = htons($src_port);
  my $dport = htons($dst_port);

  $src_first = 1 if (($sip < $dip) || (($sip == $dip) && ($sport < $dport)));

  return($src_first?"${proto}-${src_ip}:${src_port}-${dst_ip}:${dst_port}":"${proto}-${dst_ip}:${dst_port}-${src_ip}:${src_port}");
}



sub ip2i($ )
{
  my($ip) = @_;

  my $normalized = htonl(unpack("L", pack("C4", split(/\./, $ip))));
  return($normalized);
}



sub close_file($$$ )
{
  my($assoc_info, $assoc, $direction) = @_;
  my $other_direction = get_other_direction($direction);
  
  if (defined($assoc_info->{$assoc}->{'fh'}) && defined($assoc_info->{$assoc}->{'fh'}->{$direction}))
  {
    my $fh = $assoc_info->{$assoc}->{'fh'}->{$direction};
    delete($assoc_info->{$assoc}->{'fh'}->{$direction});
    if (!defined($assoc_info->{$assoc}->{'fh'}->{$other_direction}) || ($fh != $assoc_info->{$assoc}->{'fh'}->{$other_direction}))
    {
      print STDERR "Closing file: $fh\n" if ($debug > 1);
      $fh->close();
    }
  }
  return;
}



sub destroy_assoc($$ )
{
  my($assoc_info, $assoc) = @_;

  print STDERR "Destroying assoc: $assoc\n" if ($debug);

  close_file($assoc_info, $assoc, DIRECTION_FROM_SOURCE);
  close_file($assoc_info, $assoc, DIRECTION_TO_SOURCE);

  delete($assoc_info->{$assoc});
  return(0);
}


sub get_other_direction($ )
{
  my($dir) = @_;
  return(DIRECTION_TO_SOURCE) if ($dir eq DIRECTION_FROM_SOURCE);
  return(DIRECTION_FROM_SOURCE);
}
