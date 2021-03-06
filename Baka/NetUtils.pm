# -*- perl -*-
#
#
# ++Copyright BAKA++
#
# Copyright © 2006-2011 The Authors. All rights reserved.
#
# This source code is licensed to you under the terms of the file
# LICENSE.TXT in this release for further details.
#
# Send e-mail to <projectbaka@baka.org> for further information.
#
# - -Copyright BAKA- -
#


##
# @file
# Random utilities useful for dealing with networks.
#

package Baka::NetUtils;
use Exporter 'import';
use Config;
use Baka::ScriptUtils qw(berror bruncmd);
@EXPORT_OK = qw (inet_atoi inet_itoa network_match network_part netmask_from_bits minimal_netmask intinfo cidr_to_netmask);


################################################################
#
# Convert a cidr length to a netmask
#
sub cidr_to_netmask($ )
{
  my($length) = @_;
  my %map;

  $map{0} = 0;
  $map{1}= 2147483648;
  $map{2}= 3221225472;
  $map{3}= 3758096384;
  $map{4}= 4026531840;
  $map{5}= 4160749568;
  $map{6}= 4227858432;
  $map{7}= 4261412864;
  $map{8}= 4278190080;
  $map{9}= 4286578688;
  $map{10}= 4290772992;
  $map{11}= 4292870144;
  $map{12}= 4293918720;
  $map{13}= 4294443008;
  $map{14}= 4294705152;
  $map{15}= 4294836224;
  $map{16}= 4294901760;
  $map{17}= 4294934528;
  $map{18}= 4294950912;
  $map{19}= 4294959104;
  $map{20}= 4294963200;
  $map{21}= 4294965248;
  $map{22}= 4294966272;
  $map{23}= 4294966784;
  $map{24}= 4294967040;
  $map{25}= 4294967168;
  $map{26}= 4294967232;
  $map{27}= 4294967264;
  $map{28}= 4294967280;
  $map{29}= 4294967288;
  $map{30}= 4294967292;
  $map{31}= 4294967294;
  $map{32}= 4294967295;

  return(inet_itoa($map{$length}))
}

################################################################
#
# Convert an IPv4 address string into an integer. NB: using pack DOES NOT
# WORK.
#
sub inet_atoi($ )
{
  my($addr) = @_;
  my $val = 0;

  my($a, $b, $c, $d) = split(/\./, $addr);

  $val = ($a<<24) | ($b<<16) | ($c<<8) | $d;
  return(($val)&0xffffffff);
}



################################################################
#
# Convert an integer into an IPv4 address string. NB: PACK DOES NOT WORK.
#
sub inet_itoa($ )
{
  my($val) = @_;

  my $a = ($val>>24)&0xff;
  my $b = ($val>>16)&0xff;
  my $c = ($val>>8)&0xff;
  my $d = $val&0xff;

  my $addr = join(".", $a, $b, $c, $d);
  return($addr);
}



################################################################
#
# Check if two IPv4 addresses are on the same network.
#
sub network_match($$$ )
{
  my($addr1, $addr2, $netmask) = @_;

  if ($netmask =~ /^\d+$/)
  {
    $netmask = cidr_to_netmask($netmask);
  }

  my $a1 = inet_atoi($addr1);
  my $a2 = inet_atoi($addr2);
  my $n = inet_atoi($netmask);

  return ((($a1&$n)&0xffffffff) == (($a2&$n)&0xffffffff));
}


################################################################
#
# Return the network part of an address as an IPv4 addr string.
#
sub network_part($$ )
{
  my($addr, $netmask) = @_;

  my $a = inet_atoi($addr);
  my $n = inet_atoi($netmask);
  my $val = ($a&$n)&0xffffffff;

  return (inet_itoa($val));
}


################################################################
#
# Return the a netmask (as an integer) based on a bit length
#
sub netmask_from_bits($ )
{
  my($bits) = @_;

  return (-1) if (($bits < 0) || ($bits > 32));

  return ((((2**$bits)-1)<<(32-$bits))&0xffffffff);
}



################################################################
#
# Return a netmask which "minimally covers" the ip range
#
sub minimal_netmask($$ )
{
  my($ip_low, $ip_hi) = @_;

  my $low = inet_atoi($ip_low);
  my $hi = inet_atoi($ip_hi);

  my $diff = ~($low ^ $hi);

  my $bit_cnt = 0;
  while($diff&((2**(31-$bit_cnt))&0xffffffff))
  {
    $bit_cnt++;
  }

  return(inet_itoa(netmask_from_bits($bit_cnt)));
}



################################################################
#
# Return interface information
# Filter flag string should look like: "+UP,-LOOBACK" (or whatever you want)
#
sub intinfo($;$$ )
{
  my($intinfo_r, $filter_flags, $log) = @_;
  my $ret;

  eval "${Config{osname}}_intinfo(\$intinfo_r, \$log)";

  if ($@)
  {
    berror($@, $log) if (defined($log));
    return(-1);
  }

  if ($filter_flags)
  {
    foreach my $flag (split(/,/, $filter_flags))
    {
      $flag =~ /([+-])(.*)/;
      $flag = $2;
      if ($1 eq "+")
      {
	foreach my $interface (keys %$intinfo_r)
	{
	  my $intflags = $intinfo_r->{$interface}->{"flags"};
	  if (!$intflags || ($intflags !~ /$flag/))
	  {
	    delete($intinfo_r->{$interface});
	  }
	}
      }
      elsif ($1 eq "-")
      {
	foreach my $interface (keys %$intinfo_r)
	{
	  my $intflags = $intinfo_r->{$interface}->{"flags"};
	  if ($intflags && ($intflags =~ /$flag/))
	  {
	    delete($intinfo_r->{$interface});
	  }
	}
      }
    }
  }
}

sub linux_intinfo($;$ )
{
  my($intinfo_r, $log) = @_;
  my(@interface_lines, %intfinfo);
  my $int;
  my @flags;

  if (defined($log))
  {
    die "Could not run ifconfig" if (bruncmd("/sbin/ifconfig -a", $log, \@interface_lines) != 0);
  }
  else
  {
    @interface_lines = `ifconfig -a 2>/dev/null`;
    die "Could not run ifconfig" if ((($?>>8)&0xff) != 0);
  }

  chomp(@interface_lines);

  foreach my $line (@interface_lines)
  {
    next if ($line =~ /^\s*$/);
    my @toks = split(/\s+/, $line);
    if ($line !~ /^\s/)
    {
      # New interface
      $int = $toks[0];
      shift @toks;
    }
    else
    {
      my $tok;
      while(!($tok = shift @toks)){}
      unshift @toks, $tok;
    }

    while (my $tok = shift @toks)
    {
      if ($tok eq "Link")
      {
	$tok = shift @toks;
	@_ = split(/:/, $tok);
	$intinfo{$int}{'type'} = $_[1];
      }
      elsif ($tok =~ /(Bcast|Mask|collisions|txqueuelen|Scope|MTU|Metric):/)
      {
	@_ = split(/:/, $tok);
	my $index = lc($_[0]);
	$intinfo{$int}{$index} = $_[1];
      }
      elsif ($tok eq "HWaddr")
      {
	$intinfo{$int}{'mac_addr'} = shift @toks;
      }
      elsif ($tok eq "inet")
      {
	$tok = shift @toks;
	@_ = split(/:/, $tok);
	$intinfo{$int}{'ip_addr'} = $_[1];
      }
      elsif ($tok eq "inet6")
      {
	shift @toks; $tok = shift @toks;
	$intinfo{$int}{'ip6_addr'} = $tok
      }
      elsif (($tok eq "RX") || ($tok eq "TX"))
      {
	my $direction = lc($tok);
	$tok = shift @toks;
	@_ = split(/:/, $tok);
	if ($_[0] eq "packets")
	{
	  $intinfo{$int}{"${direction}_packets"} = $_[1];
	  while ($tok = shift @toks)
	  {
	    @_ = split(/:/, $tok);
	    $intinfo{$int}{"${direction}_${_[0]}"} = $_[1];

	  }
	}
	elsif ($_[0] eq "bytes")
	{
	  $intinfo{$int}{"${direction}_bytes"} = $_[1];
	}
      }
      elsif ($tok =~ /^[A-Z]+$/)
      {
	$intinfo{$int}{"flags"} .= "$tok ";
      }
    }
  }
  %$intinfo_r = %intinfo;
  return(0);
}
