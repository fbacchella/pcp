#!/usr/bin/env perl
#
# Copyright (c) 2008-2009 Silicon Graphics, Inc.  All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 2 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
#

# NOTE: To work properly with the cluster PMDA, a sub-PMDA must use zeroes in
# the most significant 4 bits of __pmID_int.cluster for all metrics, and in
# the most significant 4 bits of __pmInDom_int.serial for all indoms.
#
# This restriction leaves the sub-PMDA 511 pmid clusters (each with 1024
# metrics), and 2^18 instance domains.
#
# The cluster PMDA uses the 4 bits internally to distinguish up to 15
# sub-PMDAs, reserving a bit pattern of all ones (0xf) for itself.  The
# sub-domains are allocated dynamically as sub-PMDAs are added to the cluster
# PMDA namespace below.

# Sub-PMDA namespace files must contain only numeric cluster numbers.

open HDR, "< cluster.h" or die "can't open cluster.h: $!";
while($_=<HDR>){
    chomp; 
    if (s/^\s*\#\s*define\s+CLUSTER_CLUSTER\s+//) {
	$cc = /^0/ ? oct($_) : $_;
    } elsif (s/^\s*\#\s*define\s+CLUSTER_INDOM\s+//) {
	$ci = /^0/ ? oct($_) : $_;
    }
}

close HDR;

# Create a map: real PMID numeric domain -> PMDA directory names

my $inMap = $ARGV[1];
my %domPmdaNames;

open INMAP, $inMap
    or die "can't open real metric name-domain to pmda dir map '$inMap': $!";

while (<INMAP>) {
    chomp;
    my ($dom, $name) = split;
    $domPmdaNames{$dom} = $name;
}
close INMAP;

# Copy the namespace entries from "clusterised" PMDAs' namespace files to the
# cluster PMDA namespace file, puting them within a "cluster { ... }"
# level in the tree.

my $subsPmns = $ARGV[0];
my $numSubDoms = 0;
my %rawDomIds;			# raw pmns domain num/#define -> sub-domain id
my @subDomDom;			# index by sub-domain id -> domain id

open PMNS, "> pmns" or die "can't create new pmns: $!";
print PMNS <<EOT;
/* Automatically generated by $0 for pmda_cluster */

EOT

open METTAB, "> metric_table.c" or die "can't create new pmns: $!";
print METTAB <<EOT;
/* Automatically generated by $0 for pmda_cluster */
#include <ctype.h>
#include "pmapi.h"
#include "impl.h"
#include "pmda.h"
#include "domain.h"
#include "cluster.h"

EOT

##############################################################################

open SUBS_PMNS, $subsPmns
    or die "can't open combined namespace for other PMDAs '$subsPmns': $!";

my $srcNode;
while ($_ = <SUBS_PMNS>) {
    chomp;
    # remove any comments contained within a line
    while (s%\/\*([^\*]*\*+[^\*\/])*[^\*]*\*+\/%%) {}

    # multiline comments
    if ($comment) {
	next unless (s%.*\*\/%%);
	$comment=0;
    } else {
	$comment=s%\/\*.*%%;
    }
    next unless /\S/;

    if (/^\w/) {			# begin pmns node
	$srcNode = $_;
	$srcNode =~ s/[\s{].*//;
	if (/^root/) {
	    print PMNS "cluster \{\n        control";
	    next;
	}
	$p = "cluster.$_";
	print PMNS "$p\n";
	$p=~s/\s*\{\s*$//;
	next;
   }
   my @fields = split;
   if (@fields == 2) {
       my ($rawDom, $rawcluster, $item) = split /:/, $fields[1];
       if (length($item) && $rawDom != 'CLUSTER') {
	   # >= 3 colon separated fields
	   if (!exists $rawDomIds{$rawDom}) {
	       # found new domain string/num in PMID, look for matching
	       # sub-PMDA domain number and allocate a new subdomain.

	       $numSubDoms >= 15 and die "only 15 sub-PMDAs are permitted";
	       (!exists $domPmdaNames{$rawDom})
		   and die "couldn't find a PMDA domain to match " .
		   "metrics for '$srcNode." . $fields[0] .
		   " = $rawDom:$rawcluster:$item";

	       $subDomDoms[$numSubDoms] = $rawDom;
	       $rawDomIds{$rawDom} = $numSubDoms++;
	   }
	   ($rawcluster >= 256)
	       and die "PMID cluster >= 256 in node '$_'\n";
	   ($rawcluster !~ /^[0-9]+$/)
	       and die "PMID cluster is not numeric in node '$_'\n";
	   ($item & 0xf00)
	       and die "PMID item > 8 bits in node '$_'\n";

	   my $cluster = $rawcluster + ($rawDomIds{$rawDom} << 8);

	   $submt .= "\tCLUSTER_PMID\($rawDom,$rawcluster,$item\),\n";
	   $mt    .= "\t\{\"$p\.$fields[0]\", \{CLUSTER_PMID\(CLUSTER,$cluster,$item\),\},\},\n";

	   # map one sub-PMDA PMID's raw domain to an equivalent
	   # pmda_cluster domain+cluster.
	   my $oldPmid = $fields[1];
	   my $newPmid = "CLUSTER:$cluster:$item";
	   s/$oldPmid/$newPmid/;
	   ++$nmet;
       }
   }
   print PMNS "$_\n";
}
close SUBS_PMNS;

print PMNS "\n";

print PMNS "cluster.control {\n";
print PMNS "        suspend_monitoring\t\tCLUSTER:$cc:0\n";
print PMNS "        delete\t\tCLUSTER:$cc:1\n";
print PMNS "        metrics\t\tCLUSTER:$cc:2\n";
print PMNS "}\n";

close PMNS;

$mt .= "\t{\"cluster.control.suspend_monitoring\", {CLUSTER_PMID(CLUSTER,$cc,0),\n";
$mt .= "\t\tPM_TYPE_U32,PM_INDOM_NULL,PM_SEM_DISCRETE,PMDA_PMUNITS(0,0,0,0,0,0)},},\n";
$mt .= "\t{\"cluster.control.delete\",             {CLUSTER_PMID(CLUSTER,$cc,1),\n";
$mt .= "\t\tPM_TYPE_U32,$ci,PM_SEM_DISCRETE,PMDA_PMUNITS(0,0,0,0,0,0)},},\n";
$mt .= "\t{\"cluster.control.suspend_monitoring\", {CLUSTER_PMID(CLUSTER,$cc,2),\n";
$mt .= "\t\tPM_TYPE_STRING,$ci,PM_SEM_DISCRETE,PMDA_PMUNITS(0,0,0,0,0,0)},},\n";


print METTAB "int ncluster_mtab = $nmet;\n";
print METTAB "pmID subcluster_mtab[] = {\n$submt};\n\n";
print METTAB "pmdaMetric cluster_mtab[] = {\n$mt};\n\n";


##############################################################################

# Create a C file with a mapping from sub-PMDA subdomains to the PMDAs' real
# PMID domains.

my $outMapPath = "subdomains.c";
open OUTMAP, "> $outMapPath"
    or die "can't write subdomains map '$outMapPath': $!";

################ hereis text ################
#                                           #
print OUTMAP <<EOT;
/* Automatically generated by $0.
 * Do not edit this file.
 */

/*
 * Index this array with a subdomain number (0..14) to get the real domain
 * number of the corresponding sub-PMDA.  The subdomain numbers are encoded
 * into the high four bits of the PMID for cluster metrics when the cluster
 * namespace is generated by $0.
 */

unsigned int subdom_dom_map[] = {
EOT
#                                           #
#################### end ####################

for (my $i = 0; $i < @subDomDoms; $i++) {
    print OUTMAP ",\n" if $i;
    print OUTMAP '    ' . $subDomDoms[$i];
}

################ hereis text ################
#                                           #
print OUTMAP <<EOT;

};
int num_subdom_dom_map = $numSubDoms;

/*
 * The PMDA names corresponding to entries in subdomain_domains may be handy
 * for debugging, etc.  Indexed by subdomain.
 */

const char* subdom_name_map[] = {
EOT
#                                           #
#################### end ####################

for (my $i = 0; $i < @subDomDoms; $i++) {
    print OUTMAP ",\n" if $i;
    print OUTMAP '    "' . $domPmdaNames{$subDomDoms[$i]} . '"';
}

################ hereis text ################
#                                           #
print OUTMAP <<EOT;

};
int num_subdom_name_map = $numSubDoms;

/*
 * Index using a __pmID_int.domain or __pmInDom_int.domain to find the
 * corresponding pmdacluster subdomain, or 0xff (no sub_PMDA available
 * for that domain).  Use a char (byte) to match dest bits and save
 * space (instead of int).  Don't squeeze to 2 x 4-bits per char and
 * shift/mask (extra code+time not worth space saved).
 */

unsigned char
dom_subdom_map[] = {
EOT
#                                           #
#################### end ####################

my $numPmidDomBits = 9;
my $subDomsSize = (1 << $numPmidDomBits); # 9 bits -> 512 values.

for (my $i = 0; $i < $subDomsSize - 1; $i++) {
    my $nPerLine = 5;
    print (OUTMAP "    ") if $i % $nPerLine == 0;
    my $width = 4;
    if (exists($rawDomIds{$i})) {
	printf(OUTMAP "%$width" . 'd', int($rawDomIds{$i}));
    } else {
	printf(OUTMAP "%$width" . 's', '0xff');
    }
    if ($i < ($subDomsSize - 1)) {
	print OUTMAP ',';
    }
    print OUTMAP "    ";
    if (($i + 1) % $nPerLine == 0) {
	printf OUTMAP "/* %3d - %3d */\n", ($i - $nPerLine + 1), $i;
    }
}

################ hereis text ################
#                                           #
print OUTMAP <<EOT;

};
int num_dom_subdom_map = $subDomsSize;
EOT
#                                           #
#################### end ####################

close OUTMAP;

##############################################################################

# Copy the help text entries from "clusterised" PMDAs' help files to the
# cluster PMDA help file, prepending "cluster." to the original metric names.

open HELP, "> help" or die "can't create new help file: $!";

sub addHelpFrom
{
    my ($path, $myHelp) = @_;
    open SUB_HELP, "< $path"
	or die "can't open other PMDA help file '$path': $!";
    while ($_=<SUB_HELP>) {
	next if (/^\#/);
	if (s/^\@\s+(\S+)// && ($m=$1)) {
	    $m =~ s/^/cluster./;
	    $m =~ s/^cluster.root/cluster/;
	    print $myHelp "@ $m $_";
	} else {
	    print $myHelp $_;
	}
    }
    close SUB_HELP;
}

for (my $i = 2; $i < @ARGV; $i++) {
    addHelpFrom($ARGV[$i], \*HELP);
    print HELP "\n";
}

# Add help for cluster-specific metrics.

print HELP <<EOH;
@ cluster.control.suspend_monitoring nonzero to suspend, zero to resume
Write nonzero to this metric to cause client nodes to stop monitoring.
Write zero to have client nodes resume monitoring.
This value persists across reboot.

@ cluster.control.metrics metrics to be collected on a given client node
Writing a newline-separated list of metric names to the instance of this
metric for a given client node changes the set of linux PMDA metrics from
that client available as cluster metrics. This value persists across reboot

@ cluster.control.delete delete instances associated with a given client node
Writing 1 to this metric for a given client node will delete all instances
associated with the client, except that PM_ERR_ISCONN is returned if the
client is currently connected.
EOH

close HELP;
