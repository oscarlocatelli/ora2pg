#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Ora2Pg;

$ENV{ORA2PG_SRC_RETRY_NO_SLEEP} = 1;

# Minimal object without calling _init (avoids config/DB).
sub make_obj {
	my (%attrs) = @_;
	my $self = bless {
		debug => 0,
		quiet => 1,
		type => 'COPY',
		pg_dsn => 'dbi:Pg:dbname=test;host=localhost',
		jobs => 1,
		oracle_copies => 1,
		parallel_tables => 1,
		log_on_error => 0,
		datadiff => 0,
		lo_import => 0,
		copy_freeze => '',
		fdw_server => '',
		oracle_fdw_data_export => 0,
		oracle_speed => 0,
		ora2pg_speed => 0,
		select_top => undef,
		global_where => '',
		where => {},
		replace_query => {},
		transform_value => {},
		tables => {},
		colinfo => {},
		data_limit => 2,
		longreadlen => 1047552,
		longtruncok => 0,
		use_lob_locator => 1,
		lob_chunk_size => 8192,
		current_total_row => 0,
		global_rows => 100,
		global_start_time => time(),
		child_count => 0,
		_src_no_sleep => 1,
		sgbd_name => 'Oracle',
		prefix => 'DBA',
		schema => undef,
		export_schema => 0,
		%attrs,
	}, 'Ora2Pg';
	return $self;
}

# Fake Oracle DBH with LOB support for LOB resume tests.
{
	package FakeOracleDBH;
	sub new {
		my ($class, %a) = @_;
		return bless {
			RowCacheSize => 0,
			err => undef,
			errstr => '',
			state => '',
			fail_loc => $a{fail_loc},
			failed_once => 0,
		}, $class;
	}
	sub do { return 1; }
	sub err { return $_[0]->{err}; }
	sub errstr { return $_[0]->{errstr}; }
	sub state { return $_[0]->{state}; }
	sub disconnect { return 1; }
	sub ora_lob_chunk_size { return 8192; }
	sub ora_lob_read {
		my ($self, $loc, $off, $cs) = @_;
		if (defined $self->{fail_loc} && $loc eq $self->{fail_loc} && !$self->{failed_once}) {
			$self->{failed_once} = 1;
			$self->{err} = 3113;
			$self->{errstr} = 'ORA-03113: end-of-file on communication channel';
			$self->{state} = '';
			return undef;
		}
		$self->{err} = undef;
		$self->{errstr} = '';
		$self->{state} = '';
		if ($off == 1) {
			return "CONTENT-$loc";
		}
		return undef;
	}
}

# Fake statement handle for bulk tests.
{
	package FakeBulkSTH;
	sub new {
		my ($class, %a) = @_;
		return bless {
			blocks => $a{blocks} || [],
			fail_at => $a{fail_at},
			fail_err => $a{fail_err},
			fail_errstr => $a{fail_errstr} || '',
			fail_state => $a{fail_state} || '',
			calls => 0,
			finished => 0,
			err => undef,
			errstr => '',
			state => '',
		}, $class;
	}
	sub fetchall_arrayref {
		my ($self, $u, $limit) = @_;
		my $idx = $self->{calls}++;
		if (defined $self->{fail_at} && $idx == $self->{fail_at}) {
			$self->{err} = $self->{fail_err};
			$self->{errstr} = $self->{fail_errstr};
			$self->{state} = $self->{fail_state};
			if ($self->{die_on_fetch}) {
				die $self->{fail_errstr};
			}
			return undef;
		}
		if ($idx >= @{$self->{blocks}} && !$self->{extra_blocks}) {
			$self->{err} = undef;
			$self->{errstr} = '';
			$self->{state} = '';
			return [];
		}
		my $b;
		if ($self->{extra_blocks} && $idx >= @{$self->{blocks}}) {
			$b = $self->{extra_blocks}->[$idx - @{$self->{blocks}}];
			if (!defined $b) {
				$self->{err} = undef;
				$self->{errstr} = '';
				$self->{state} = '';
				return [];
			}
		} else {
			$b = $self->{blocks}->[$idx];
		}
		$self->{err} = undef;
		$self->{errstr} = '';
		$self->{state} = '';
		return $b;
	}
	sub err { return $_[0]->{err}; }
	sub errstr { return $_[0]->{errstr}; }
	sub state { return $_[0]->{state}; }
	sub finish { $_[0]->{finished} = 1; return 1; }
	sub execute { return 1; }
}

# Fake row-by-row handle.
{
	package FakeRowSTH;
	sub new {
		my ($class, %a) = @_;
		return bless {
			rows => $a{rows} || [],
			fail_at => $a{fail_at},
			fail_err => $a{fail_err},
			fail_errstr => $a{fail_errstr} || '',
			fail_state => $a{fail_state} || '',
			die_on_fetch => $a{die_on_fetch} || 0,
			calls => 0,
			err => undef,
			errstr => '',
			state => '',
		}, $class;
	}
	sub fetchrow_array {
		my ($self) = @_;
		my $idx = $self->{calls}++;
		if (defined $self->{fail_at} && $idx == $self->{fail_at}) {
			$self->{err} = $self->{fail_err};
			$self->{errstr} = $self->{fail_errstr};
			$self->{state} = $self->{fail_state};
			if ($self->{die_on_fetch}) {
				die $self->{fail_errstr};
			}
			return ();
		}
		if ($idx >= @{$self->{rows}}) {
			$self->{err} = undef;
			$self->{errstr} = '';
			$self->{state} = '';
			return ();
		}
		$self->{err} = undef;
		$self->{errstr} = '';
		$self->{state} = '';
		return @{$self->{rows}->[$idx]};
	}
	sub err { return $_[0]->{err}; }
	sub errstr { return $_[0]->{errstr}; }
	sub state { return $_[0]->{state}; }
	sub finish { return 1; }
	sub execute { return 1; }
}

# --- 1. Oracle allowlist ---
{
	my $o = make_obj();
	ok($o->_src_is_retryable(3113, 'ORA-03113: end-of-file on communication channel', '', 'read'), 'ORA-03113 retryable');
	ok($o->_src_is_retryable(3114, 'ORA-03114: not connected to ORACLE', '', 'read'), 'ORA-03114 retryable');
	ok($o->_src_is_retryable(3135, 'ORA-03135: connection lost contact', '', 'read'), 'ORA-03135 retryable');
	ok($o->_src_is_retryable(1012, 'ORA-01012: not logged on', '', 'read'), 'ORA-01012 retryable');
	ok($o->_src_is_retryable(1033, 'ORA-01033: ORACLE initialization or shutdown in progress', '', 'read'), 'ORA-01033 retryable');
	ok($o->_src_is_retryable(1034, 'ORA-01034: ORACLE not available', '', 'read'), 'ORA-01034 retryable');
	ok($o->_src_is_retryable(1089, 'ORA-01089: immediate shutdown in progress', '', 'read'), 'ORA-01089 retryable');
	ok($o->_src_is_retryable(12541, 'ORA-12541: TNS:no listener', '', 'read'), 'ORA-12541 retryable');
	ok(!$o->_src_is_retryable(942, 'ORA-00942: table or view does not exist', '', 'read'), 'ORA-00942 not retryable');
	ok(!$o->_src_is_retryable(1722, 'ORA-01722: invalid number', '', 'read'), 'ORA-01722 not retryable');
	ok(!$o->_src_is_retryable(1555, 'ORA-01555: snapshot too old', '', 'read'), 'ORA-01555 not retryable');
	ok(!$o->_src_is_retryable(1, 'ORA-00001: unique constraint violated', '', 'read'), 'ORA-00001 not retryable');
	ok(!$o->_src_is_retryable(undef, 'some unknown error', '', 'read'), 'unknown oracle error not retryable');
}

# --- 2. MSSQL allowlist ---
{
	my $m = make_obj(is_mssql => 1, sgbd_name => 'MSSQL');
	ok($m->_src_is_retryable(undef, '[08S01] Communication link failure', '08S01', 'read'), '08S01 retryable');
	ok($m->_src_is_retryable(undef, '[08003] Connection does not exist', '08003', 'read'), '08003 retryable');
	ok($m->_src_is_retryable(undef, '[08006] Connection failure', '08006', 'read'), '08006 retryable');
	ok(!$m->_src_is_retryable(undef, '[08001] certificate verify failed (TLS)', '08001', 'read'), '08001 TLS not retryable on read');
	ok(!$m->_src_is_retryable(undef, '[28000] Login failed for user', '28000', 'read'), '28000 auth not retryable');
	ok(!$m->_src_is_retryable(undef, '[42S02] Invalid object name', '42S02', 'read'), '42xxx not retryable');
	ok(!$m->_src_is_retryable(undef, '[23000] Integrity constraint violation', '23000', 'read'), '23xxx not retryable');
	ok(!$m->_src_is_retryable(undef, '[HYT00] Query timeout expired', 'HYT00', 'read'), 'statement timeout not retryable on read');
	ok(!$m->_src_is_retryable(undef, 'mystery failure', '', 'read'), 'unknown mssql not retryable');
	# Connect phase: login timeout without TLS is retryable when state matches.
	ok($m->_src_is_retryable(undef, '[08001] Login timeout expired (TCP Provider)', '08001', 'connect'), '08001 login timeout retryable on connect');
	ok(!$m->_src_is_retryable(undef, '[08001] certificate verify failed', '08001', 'connect'), '08001 TLS still not retryable on connect');
}

# --- 3. Resume capability: happy path + fallbacks ---
{
	my $o = make_obj();
	$o->{tables}{T1}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$o->{tables}{T1}{column_info} = {
		ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'T1', '', 'NO', 1],
		NAME => ['NAME', 'VARCHAR2', 30, 'Y', undef, undef, undef, undef, 'T1', '', 'NO', 2],
	};
	my ($info, $reason) = $o->_src_resume_info('T1', ['ID', 'NAME'], ['NUMBER', 'VARCHAR2'], undef);
	ok(defined $info, 'single NUMBER PK resumable');
	is($info->{pk_idx}, 0, 'pk idx 0');
	like($info->{pk_alias_quoted}, qr/^a\."ID"$/, 'oracle quoting');

	# Composite
	$o->{tables}{T1}{unique_key} = { PK1 => { type => 'P', columns => ['ID', 'NAME'] } };
	($info, $reason) = $o->_src_resume_info('T1', ['ID', 'NAME'], ['NUMBER', 'VARCHAR2'], undef);
	ok(!defined $info && $reason =~ /composita/i, 'composite PK fallback');

	# Missing
	$o->{tables}{T1}{unique_key} = {};
	($info, $reason) = $o->_src_resume_info('T1', ['ID', 'NAME'], ['NUMBER', 'VARCHAR2'], undef);
	ok(!defined $info && $reason =~ /assente/i, 'missing PK fallback');

	# Transformed
	$o->{tables}{T1}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$o->{transform_value} = { t1 => { id => 'TO_CHAR(ID)' } };
	($info, $reason) = $o->_src_resume_info('T1', ['ID', 'NAME'], ['NUMBER', 'VARCHAR2'], undef);
	ok(!defined $info && $reason =~ /TRANSFORM/i, 'transformed PK fallback');
	$o->{transform_value} = {};

	# Excluded from projection
	($info, $reason) = $o->_src_resume_info('T1', ['NAME'], ['VARCHAR2'], undef);
	ok(!defined $info && $reason =~ /proiezione/i, 'excluded PK fallback');

	# Non-exact type
	$o->{tables}{T1}{column_info} = {
		ID => ['ID', 'BINARY_FLOAT', 12, 'N', undef, undef, undef, undef, 'T1', '', 'NO', 1],
		NAME => ['NAME', 'VARCHAR2', 30, 'Y', undef, undef, undef, undef, 'T1', '', 'NO', 2],
	};
	($info, $reason) = $o->_src_resume_info('T1', ['ID', 'NAME'], ['BINARY_FLOAT', 'VARCHAR2'], undef);
	ok(!defined $info, 'float PK not resumable');

	# Parallelism
	my $p = make_obj();
	$p->{tables}{T1}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$p->{tables}{T1}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'T1', '', 'NO', 1] };
	$p->{jobs} = 2;
	($info, $reason) = $p->_src_resume_info('T1', ['ID'], ['NUMBER'], undef);
	ok(!defined $info && $reason =~ /parallelismo/i, 'parallel fallback');

	# File export
	my $f = make_obj(pg_dsn => undef);
	$f->{tables}{T1}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$f->{tables}{T1}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'T1', '', 'NO', 1] };
	($info, $reason) = $f->_src_resume_info('T1', ['ID'], ['NUMBER'], undef);
	ok(!defined $info && $reason =~ /file/i, 'file fallback');

	# LOG_ON_ERROR
	my $l = make_obj(log_on_error => 1);
	$l->{tables}{T1}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$l->{tables}{T1}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'T1', '', 'NO', 1] };
	($info, $reason) = $l->_src_resume_info('T1', ['ID'], ['NUMBER'], undef);
	ok(!defined $info && $reason =~ /LOG_ON_ERROR/i, 'log_on_error fallback');

	# Partitioned
	my $pt = make_obj();
	$pt->{tables}{T1}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$pt->{tables}{T1}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'T1', '', 'NO', 1] };
	($info, $reason) = $pt->_src_resume_info('T1', ['ID'], ['NUMBER'], 'P1');
	ok(!defined $info && $reason =~ /partizionata/i, 'partitioned fallback');

	# MSSQL exact types
	my $ms = make_obj(is_mssql => 1, sgbd_name => 'MSSQL');
	$ms->{tables}{T1}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$ms->{tables}{T1}{column_info} = { ID => ['ID', 'int', 4, 'N', undef, undef, undef, undef, 'T1', '', 'NO', 1] };
	($info, $reason) = $ms->_src_resume_info('T1', ['ID'], ['int'], undef);
	ok(defined $info, 'mssql int resumable');
	like($info->{pk_alias_quoted}, qr/^a\.\[ID\]$/, 'mssql quoting');
	$ms->{tables}{T1}{column_info} = { ID => ['ID', 'float', 8, 'N', undef, undef, undef, undef, 'T1', '', 'NO', 1] };
	($info, $reason) = $ms->_src_resume_info('T1', ['ID'], ['float'], undef);
	ok(!defined $info, 'mssql float not resumable');
}

# --- 4. Query building: ORDER BY, WHERE variants, placeholder, no interpolation ---
{
	my $o = make_obj();
	$o->{tables}{QT}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$o->{tables}{QT}{column_info} = {
		ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'QT', '', 'NO', 1],
		NAME => ['NAME', 'VARCHAR2', 10, 'Y', undef, undef, undef, undef, 'QT', '', 'NO', 2],
	};
	$o->{tables}{QT}{table_info} = { nested => 'NO', owner => 'SC', num_rows => 10 };
	$o->{colinfo} = { QT => { ID => { nullable => 'N' }, NAME => { nullable => 'Y' } } };
	$o->{prefix} = 'DBA';
	$o->{data_type} = { NUMBER => 'numeric', VARCHAR2 => 'varchar' };
	$o->{user_type} = {};
	$o->{spatial_srid} = {};
	$o->{nullable} = {};
	$o->{local_data_limit} = {};
	$o->{bfile_found} = '';
	$o->{has_dbms_log_execute_privilege} = 0;
	$o->{empty_lob_null} = 0;
	$o->{enable_blob_export} = 1;
	$o->{enable_clob_export} = 1;
	$o->{trim_type} = 'BOTH';
	$o->{trim_char} = ' ';
	$o->{geometry_extract_type} = 'WKT';

	my $nn = ['ID', 'NAME'];
	my $tt = ['bigint', 'varchar'];
	my $stt = ['NUMBER', 'VARCHAR2'];
	my $q = $o->_howto_get_data('QT', $nn, $tt, $stt, undef, undef);
	like($q, qr/ORDER BY a\."ID"/, 'initial query ordered');
	ok(exists $o->{_src_resume}{QT}, 'resume template stored');
	is($o->{_src_resume}{QT}{has_where}, 0, 'no where flag');
	my $rsql = $o->_src_resume_sql('QT');
	like($rsql, qr/WHERE a\."ID" > \? ORDER BY a\."ID"/, 'resume predicate with placeholder');
	unlike($rsql, qr/123|999/, 'no ID interpolated');

	# WHERE present
	$o->{where} = { qt => "NAME = 'x'" };
	$nn = ['ID', 'NAME'];
	$q = $o->_howto_get_data('QT', $nn, $tt, $stt, undef, undef);
	like($q, qr/WHERE \(NAME = 'x'\) ORDER BY/, 'where preserved with order');
	is($o->{_src_resume}{QT}{has_where}, 1, 'where flag set');
	$rsql = $o->_src_resume_sql('QT');
	like($rsql, qr/\(NAME = 'x'\) AND a\."ID" > \?/, 'resume AND after filter');

	# WHERE with OR needs parens (generator already parenthesizes)
	$o->{where} = { qt => "NAME = 'x' OR NAME = 'y'" };
	$nn = ['ID', 'NAME'];
	$q = $o->_howto_get_data('QT', $nn, $tt, $stt, undef, undef);
	like($q, qr/\(NAME = 'x' OR NAME = 'y'\)/, 'OR filter parenthesized');
	$rsql = $o->_src_resume_sql('QT');
	like($rsql, qr/\) AND a\."ID" > \?/, 'OR + resume AND correct');

	# Rename destination must not affect source ORDER BY (uses source name)
	$o->{where} = {};
	$o->{replaced_cols} = { qt => { id => 'ID_NEW' } };
	$nn = ['ID', 'NAME'];
	$q = $o->_howto_get_data('QT', $nn, $tt, $stt, undef, undef);
	like($q, qr/ORDER BY a\."ID"/, 'order uses source column despite rename');
	delete $o->{replaced_cols};
}

# --- 5. logit guard: no global cleanup inside protected attempts ---
{
	my $o = make_obj();
	my $logfile = "/tmp/t_tmp_guard.log";
	unlink $logfile if (-e $logfile);
	open(my $fh, '>', $logfile) or die "cannot write $logfile: $!";
	$o->{fhlog} = $fh;
	my $fake_dbh = bless { disconnected => 0 }, 'FakeGuardDBH';
	{
		package FakeGuardDBH;
		sub disconnect { $_[0]->{disconnected} = 1; return 1; }
	}
	$o->{dbh} = $fake_dbh;
	$o->{dbhdest} = bless({ disconnected => 0 }, 'FakeGuardDBH');
	$o->{_src_retry_active} = 1;
	my $died = '';
	eval { $o->logit("FATAL: ORA-03113 boom\n", 0, 1); 1; } or $died = $@;
	like($died, qr/^ORA2PG_SRC_RETRY:FATAL/, 'marker propagated');
	ok(!$fake_dbh->{disconnected}, 'source handle not disconnected during retry');
	ok(!$o->{dbhdest}->{disconnected}, 'PG handle preserved during retry');
	ok(-e $logfile, 'logfile preserved during retry');
	close($fh);
	unlink $logfile;
	$o->{_src_retry_active} = undef;
}

# --- 6. Bulk resume integration: failure after two blocks, then resume ---
{
	my $o = make_obj(data_limit => 2);
	$o->{tables}{BT}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$o->{tables}{BT}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'BT', '', 'NO', 1] };
	$o->{tables}{BT}{table_info} = { num_rows => 6 };
	$o->{_src_resume}{BT} = {
		pk_idx => 0,
		pk_alias_quoted => 'a."ID"',
		base => 'SELECT a."ID" FROM "BT" a',
		has_where => 0,
		order => ' ORDER BY a."ID"',
	};
	my $initial = 'SELECT a."ID" FROM "BT" a ORDER BY a."ID"';

	my @sent_ids = ();
	my @checkpoints = ();
	my $reconnects = 0;
	no warnings 'redefine';
	local *Ora2Pg::_dump_to_pg = sub {
		my ($self, $proc, $rows, $table, @rest) = @_;
		# Capture raw PK before any formatting (mimic real capture point).
		my $pk = $rows->[-1]->[0];
		push(@checkpoints, "$pk");
		foreach my $r (@$rows) { push(@sent_ids, "$r->[0]"); }
		return 1;
	};
	# First STH: two good blocks then ORA-03113; second STH: remaining rows.
	my $first_sth = FakeBulkSTH->new(
		blocks => [[[1], [2]], [[3], [4]]],
		fail_at => 2,
		fail_err => 3113,
		fail_errstr => 'ORA-03113: end-of-file on communication channel',
		fail_state => '',
	);
	my $second_sth = FakeBulkSTH->new(blocks => [[[5], [6]]]);
	my @sths = ($first_sth, $second_sth);
	my $prep_calls = 0;
	my @got_sql_bind = ();
	local *Ora2Pg::_src_prepare_source_sth = sub {
		my ($self, $table, $sql) = @_;
		$prep_calls++;
		return $sths[$prep_calls - 1];
	};
	# Fake execute: our FakeBulkSTH execute always ok; need to simulate bind capture.
	# Patch FakeBulkSTH execute to record bind via closure below instead:
	# Instead drive _extract_resumable_bulk with overridden prepare that also handles execute.
	# Simplify: give STHs an execute that records.
	foreach my $s (@sths) {
		no warnings 'redefine';
		*s = *s; # keep
	}
	# Our _extract_resumable_bulk calls $sth->execute(@bind) after prepare.
	# FakeBulkSTH lacks execute; add it.
	*FakeBulkSTH::execute = sub { return 1; };

	local *Ora2Pg::_src_reconnect = sub {
		my ($self, $table, $phase, $diag, $cp) = @_;
		$reconnects++;
		# Verify diagnosis preserved and checkpoint is last confirmed (4).
		is("$cp", '4', 'checkpoint is last confirmed after two blocks') if ($reconnects == 1);
		like($diag->{errstr} || '', qr/ORA-03113/, 'diagnosis preserved');
		return bless({}, 'FakeDBH2');
	};

	my $total = $o->_extract_resumable_bulk($initial, 'BT', [], [], 'INSERT', ['ID'], ['bigint'], '', ['NUMBER'], undef, undef, {});
	is($total, 6, 'total confirmed 6 after resume');
	is($reconnects, 1, 'one reconnect');
	is_deeply(\@sent_ids, [qw(1 2 3 4 5 6)], 'IDs in order, no resend of confirmed');
	my @tail_ids = @sent_ids[4, 5];
	my $resent = grep { $_ <= 4 } @tail_ids;
	ok($resent == 0, 'IDs <= checkpoint not resent');
	is($o->{current_total_row}, 6, 'global counter exact, no double count');
}

# --- 7. Failure before any confirmation restarts from initial query ---
{
	my $o = make_obj(data_limit => 2);
	$o->{tables}{BT2}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$o->{tables}{BT2}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'BT2', '', 'NO', 1] };
	$o->{tables}{BT2}{table_info} = { num_rows => 2 };
	$o->{_src_resume}{BT2} = {
		pk_idx => 0, pk_alias_quoted => 'a."ID"',
		base => 'SELECT a."ID" FROM "BT2" a', has_where => 0, order => ' ORDER BY a."ID"',
	};
	my $initial = 'SELECT a."ID" FROM "BT2" a ORDER BY a."ID"';
	my @sent = ();
	my @resume_sqls = ();
	no warnings 'redefine';
	local *Ora2Pg::_dump_to_pg = sub {
		my ($self, $proc, $rows, @rest) = @_;
		foreach my $r (@$rows) { push(@sent, "$r->[0]"); }
		return 1;
	};
	my $fail_sth = FakeBulkSTH->new(fail_at => 0, fail_err => 3113, fail_errstr => 'ORA-03113: boom', fail_state => '');
	my $ok_sth = FakeBulkSTH->new(blocks => [[[7], [8]]]);
	my @sths = ($fail_sth, $ok_sth);
	my $n = 0;
	local *Ora2Pg::_src_prepare_source_sth = sub { $n++; return $sths[$n - 1]; };
	*FakeBulkSTH::execute = sub { return 1; };
	my $saw_initial_on_retry = 0;
	local *Ora2Pg::_src_reconnect = sub {
		my ($self, $table, $phase, $diag, $cp) = @_;
		ok(!defined $cp, 'no checkpoint before any confirmation');
		return bless({}, 'FakeDBH2');
	};
	# Capture SQL used for second prepare by wrapping _src_resume_sql? Instead inspect via prepare mock.
	# Our prepare mock ignores SQL; verify by checking that second STH got initial rows (7,8) not filtered.
	my $total = $o->_extract_resumable_bulk($initial, 'BT2', [], [], 'INSERT', ['ID'], ['bigint'], '', ['NUMBER'], undef, undef, {});
	is($total, 2, 'restart from initial when nothing confirmed');
	is_deeply(\@sent, [qw(7 8)], 'rows from initial query');
}

# --- 8. Exact PK beyond 2^53 kept as string, placeholder used ---
{
	my $o = make_obj(data_limit => 2);
	$o->{tables}{BIG}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$o->{tables}{BIG}{column_info} = { ID => ['ID', 'NUMBER', 38, 'N', undef, undef, undef, undef, 'BIG', '', 'NO', 1] };
	$o->{tables}{BIG}{table_info} = { num_rows => 3 };
	$o->{_src_resume}{BIG} = {
		pk_idx => 0, pk_alias_quoted => 'a."ID"',
		base => 'SELECT a."ID" FROM "BIG" a', has_where => 0, order => ' ORDER BY a."ID"',
	};
	my $big1 = '9007199254740993';
	my $big2 = '9007199254740994';
	my $big3 = '9007199254740995';
	my $initial = 'SELECT a."ID" FROM "BIG" a ORDER BY a."ID"';
	my @binds = ();
	no warnings 'redefine';
	local *Ora2Pg::_dump_to_pg = sub { return 1; };
	my $sth1 = FakeBulkSTH->new(blocks => [[[$big1], [$big2]]], fail_at => 1, fail_err => 3113, fail_errstr => 'ORA-03113: boom', fail_state => '');
	my $sth2 = FakeBulkSTH->new(blocks => [[[$big3]]]);
	my @sths = ($sth1, $sth2);
	my $k = 0;
	local *Ora2Pg::_src_prepare_source_sth = sub { $k++; return $sths[$k - 1]; };
	*FakeBulkSTH::execute = sub {
		my ($self, @b) = @_;
		@binds = @b if (@b);
		return 1;
	};
	# Need execute that records binds: our FakeBulkSTH execute ignores binds, so wrap prepare to return STH with custom execute.
	# Instead patch _extract_resumable_bulk bind path indirectly: verify checkpoint string exact via _dump_to_pg capture.
	my @cps = ();
	local *Ora2Pg::_dump_to_pg = sub {
		my ($self, $proc, $rows, @rest) = @_;
		push(@cps, $rows->[-1]->[0] . '');
		return 1;
	};
	local *Ora2Pg::_src_reconnect = sub { return bless({}, 'FakeDBH2'); };
	my $total = $o->_extract_resumable_bulk($initial, 'BIG', [], [], 'INSERT', ['ID'], ['bigint'], '', ['NUMBER'], undef, undef, {});
	is($total, 3, 'big IDs total');
	is($cps[0], $big2, 'checkpoint exact string beyond 2^53');
	# Resume SQL must use placeholder, never interpolated ID.
	my $rsql = $o->_src_resume_sql('BIG');
	unlike($rsql, qr/900719925474099/, 'no big ID interpolated in SQL');
	like($rsql, qr/> \?/, 'placeholder used');
}

# --- 9. PG failure never advances checkpoint (COPY and INSERT) ---
{
	foreach my $t (qw(COPY INSERT)) {
		my $o = make_obj(type => $t, data_limit => 2);
		$o->{tables}{PGF}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
		$o->{tables}{PGF}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'PGF', '', 'NO', 1] };
		$o->{tables}{PGF}{table_info} = { num_rows => 4 };
		$o->{_src_resume}{PGF} = {
			pk_idx => 0, pk_alias_quoted => 'a."ID"',
			base => 'SELECT a."ID" FROM "PGF" a', has_where => 0, order => ' ORDER BY a."ID"',
		};
		my $initial = 'SELECT a."ID" FROM "PGF" a ORDER BY a."ID"';
		no warnings 'redefine';
		local *Ora2Pg::_src_prepare_source_sth = sub {
			return FakeBulkSTH->new(blocks => [[[1], [2]]]);
		};
		*FakeBulkSTH::execute = sub { return 1; };
		local *Ora2Pg::_dump_to_pg = sub {
			# Simulate ambiguous PG failure: die FATAL (not retryable as source).
			die "FATAL: PG copy failed\n";
		};
		local *Ora2Pg::_src_reconnect = sub {
			fail("PG failure must not trigger source reconnect ($t)");
			return undef;
		};
		my $died = '';
		eval { $o->_extract_resumable_bulk($initial, 'PGF', [], [], 'X', ['ID'], ['bigint'], '', ['NUMBER'], undef, undef, {}); 1; } or $died = $@;
		like($died, qr/PG copy failed/, "PG $t failure propagates, no replay");
		is($o->{current_total_row}, 0, "PG $t failure: counters not advanced");
	}
}

# --- 10. MSSQL RaiseError during execute/fetch terminates or retries correctly ---
{
	# RaiseError with retryable state retries.
	my $m = make_obj(is_mssql => 1, sgbd_name => 'MSSQL', data_limit => 2);
	$m->{tables}{MT}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$m->{tables}{MT}{column_info} = { ID => ['ID', 'int', 4, 'N', undef, undef, undef, undef, 'MT', '', 'NO', 1] };
	$m->{tables}{MT}{table_info} = { num_rows => 2 };
	$m->{_src_resume}{MT} = {
		pk_idx => 0, pk_alias_quoted => 'a.[ID]',
		base => 'SELECT a.[ID] FROM [MT] a', has_where => 0, order => ' ORDER BY a.[ID]',
	};
	my $initial = 'SELECT a.[ID] FROM [MT] a ORDER BY a.[ID]';
	no warnings 'redefine';
	my $fail = FakeBulkSTH->new(fail_at => 0, fail_err => undef, fail_errstr => '[08S01] Communication link failure', fail_state => '08S01', die_on_fetch => 0);
	# Simulate RaiseError die instead:
	$fail->{die_on_fetch} = 1;
	my $ok = FakeBulkSTH->new(blocks => [[[1], [2]]]);
	my @sths = ($fail, $ok);
	my $n = 0;
	local *Ora2Pg::_src_prepare_source_sth = sub { $n++; return $sths[$n - 1]; };
	*FakeBulkSTH::execute = sub { return 1; };
	local *Ora2Pg::_dump_to_pg = sub { return 1; };
	my $rc = 0;
	local *Ora2Pg::_src_reconnect = sub { $rc++; return bless({}, 'FakeDBH2'); };
	my $total = $m->_extract_resumable_bulk($initial, 'MT', [], [], 'X', ['ID'], ['integer'], '', ['int'], undef, undef, {});
	is($total, 2, 'mssql retryable RaiseError resumes');
	is($rc, 1, 'one reconnect for mssql');

	# Non-retryable MSSQL (auth) terminates.
	my $m2 = make_obj(is_mssql => 1, sgbd_name => 'MSSQL', data_limit => 2);
	$m2->{tables}{MT}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$m2->{tables}{MT}{column_info} = { ID => ['ID', 'int', 4, 'N', undef, undef, undef, undef, 'MT', '', 'NO', 1] };
	$m2->{tables}{MT}{table_info} = { num_rows => 2 };
	$m2->{_src_resume}{MT} = {
		pk_idx => 0, pk_alias_quoted => 'a.[ID]',
		base => 'SELECT a.[ID] FROM [MT] a', has_where => 0, order => ' ORDER BY a.[ID]',
	};
	local *Ora2Pg::_src_prepare_source_sth = sub {
		return FakeBulkSTH->new(fail_at => 0, fail_err => 1, fail_errstr => '[28000] Login failed', fail_state => '28000', die_on_fetch => 1);
	};
	local *Ora2Pg::_src_reconnect = sub { fail('auth must not reconnect'); return undef; };
	my $died = '';
	eval { $m2->_extract_resumable_bulk($initial, 'MT', [], [], 'X', ['ID'], ['integer'], '', ['int'], undef, undef, {}); 1; } or $died = $@;
	like($died, qr/Aborting|Login failed|FATAL/i, 'mssql auth terminates');
}

# --- 11. _src_retry_column_attributes preserves list context ---
{
	my $o = make_obj();
	no warnings 'redefine';
	my $calls = 0;
	local *Ora2Pg::_column_attributes = sub {
		my ($self, $table, $owner, $t) = @_;
		$calls++;
		if ($calls == 1) {
			$self->logit("FATAL: ORA-03113: boom\n", 0, 1);
		}
		return (TAB1 => { COL1 => { nullable => 'N' } }, TAB1b => { COL2 => { nullable => 'Y' } });
	};
	local *Ora2Pg::_src_reconnect = sub { return bless({ prefix => 'DBA' }, 'FakeDBH2'); };
	$o->{prefix} = 'DBA';
	$o->{user_grants} = 0;
	my %h = $o->_src_retry_column_attributes('TAB1', undef);
	is($calls, 2, 'metadata retried once');
	ok(exists $h{TAB1}, 'list context preserved (hash, not scalar)');
	is($h{TAB1}{COL1}{nullable}, 'N', 'metadata content intact');
}

# --- 12. Permanent error during reconnect exits FATAL once ---
{
	my $o = make_obj();
	$o->{_src_retry_active} = undef;
	no warnings 'redefine';
	local *Ora2Pg::_db_connection = sub {
		die "ORA2PG_SRC_RETRY:FATAL: ORA-00942: table or view does not exist\n";
	};
	# Directly test classification: permanent reconnect error must die FATAL (Aborting), not loop.
	# We simulate _src_reconnect with a _db_connection that always gives permanent error,
	# but to avoid infinite loop we check that it dies quickly (no sleep due to env).
	my $died = '';
	# _src_reconnect loops forever on retryable; permanent must die on first attempt.
	# Use timeout guard via alarm? Just call and expect die.
	eval {
		local $ENV{ORA2PG_SRC_RETRY_NO_SLEEP} = 1;
		$o->_src_reconnect('T', 'read', { err => 3113, errstr => 'ORA-03113: boom', state => '' }, undef);
		1;
	} or $died = $@;
	# This will actually retry reconnect (since initial diag is retryable) and then hit permanent
	# _db_connection permanent -> FATAL -> Aborting. So expect Aborting.
	like($died, qr/Aborting|ORA-00942/i, 'permanent reconnect error exits FATAL');
}

# --- 13. Empty table and final partial flush (no false completion) ---
{
	my $o = make_obj(data_limit => 2);
	$o->{tables}{EMP}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$o->{tables}{EMP}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'EMP', '', 'NO', 1] };
	$o->{tables}{EMP}{table_info} = { num_rows => 0 };
	$o->{_src_resume}{EMP} = {
		pk_idx => 0, pk_alias_quoted => 'a."ID"',
		base => 'SELECT a."ID" FROM "EMP" a', has_where => 0, order => ' ORDER BY a."ID"',
	};
	no warnings 'redefine';
	my $dumps = 0;
	local *Ora2Pg::_dump_to_pg = sub { $dumps++; return 1; };
	local *Ora2Pg::_src_prepare_source_sth = sub {
		return FakeBulkSTH->new(blocks => []);
	};
	*FakeBulkSTH::execute = sub { return 1; };
	local *Ora2Pg::_src_reconnect = sub { fail('empty table must not reconnect'); return undef; };
	my $total = $o->_extract_resumable_bulk('SELECT a."ID" FROM "EMP" a ORDER BY a."ID"', 'EMP', [], [], 'X', ['ID'], ['bigint'], '', ['NUMBER'], undef, undef, {});
	is($total, 0, 'empty table returns 0');
	is($dumps, 0, 'empty table never calls writer');

	# Final partial: 3 rows with limit 2 -> blocks [2,1].
	$o->{tables}{PAR}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$o->{tables}{PAR}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'PAR', '', 'NO', 1] };
	$o->{tables}{PAR}{table_info} = { num_rows => 3 };
	$o->{_src_resume}{PAR} = {
		pk_idx => 0, pk_alias_quoted => 'a."ID"',
		base => 'SELECT a."ID" FROM "PAR" a', has_where => 0, order => ' ORDER BY a."ID"',
	};
	my @ids = ();
	local *Ora2Pg::_dump_to_pg = sub {
		my ($self, $proc, $rows, @rest) = @_;
		foreach my $r (@$rows) { push(@ids, "$r->[0]"); }
		return 1;
	};
	local *Ora2Pg::_src_prepare_source_sth = sub {
		return FakeBulkSTH->new(blocks => [[[1], [2]], [[3]]]);
	};
	my $t2 = $o->_extract_resumable_bulk('SELECT a."ID" FROM "PAR" a ORDER BY a."ID"', 'PAR', [], [], 'X', ['ID'], ['bigint'], '', ['NUMBER'], undef, undef, {});
	is($t2, 3, 'final partial flushed');
	is_deeply(\@ids, [qw(1 2 3)], 'partial IDs exact');
}

# --- 14. EOF with error retries, partial rows with err discarded ---
{
	my $o = make_obj(data_limit => 2);
	$o->{tables}{EOFE}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$o->{tables}{EOFE}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'EOFE', '', 'NO', 1] };
	$o->{tables}{EOFE}{table_info} = { num_rows => 4 };
	$o->{_src_resume}{EOFE} = {
		pk_idx => 0, pk_alias_quoted => 'a."ID"',
		base => 'SELECT a."ID" FROM "EOFE" a', has_where => 0, order => ' ORDER BY a."ID"',
	};
	no warnings 'redefine';
	my @sent = ();
	local *Ora2Pg::_dump_to_pg = sub {
		my ($self, $proc, $rows, @rest) = @_;
		foreach my $r (@$rows) { push(@sent, "$r->[0]"); }
		return 1;
	};
	# First STH: one good block then EOF-with-error (undef + ORA-03113).
	my $s1 = FakeBulkSTH->new(blocks => [[[1], [2]]], fail_at => 1, fail_err => 3113, fail_errstr => 'ORA-03113: boom', fail_state => '');
	my $s2 = FakeBulkSTH->new(blocks => [[[3], [4]]]);
	my @sths = ($s1, $s2);
	my $k = 0;
	local *Ora2Pg::_src_prepare_source_sth = sub { $k++; return $sths[$k - 1]; };
	*FakeBulkSTH::execute = sub { return 1; };
	my $rc = 0;
	local *Ora2Pg::_src_reconnect = sub { $rc++; return bless({}, 'FakeDBH2'); };
	my $total = $o->_extract_resumable_bulk('SELECT a."ID" FROM "EOFE" a ORDER BY a."ID"', 'EOFE', [], [], 'X', ['ID'], ['bigint'], '', ['NUMBER'], undef, undef, {});
	is($total, 4, 'EOF with error resumes, no false completion');
	is($rc, 1, 'EOF error triggers one reconnect');
	is_deeply(\@sent, [qw(1 2 3 4)], 'no duplication after EOF error');
}

# --- 15. New failure after resume (two reconnects, no duplication) ---
{
	my $o = make_obj(data_limit => 2);
	$o->{tables}{TW}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$o->{tables}{TW}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'TW', '', 'NO', 1] };
	$o->{tables}{TW}{table_info} = { num_rows => 6 };
	$o->{_src_resume}{TW} = {
		pk_idx => 0, pk_alias_quoted => 'a."ID"',
		base => 'SELECT a."ID" FROM "TW" a', has_where => 0, order => ' ORDER BY a."ID"',
	};
	no warnings 'redefine';
	my @sent = ();
	local *Ora2Pg::_dump_to_pg = sub {
		my ($self, $proc, $rows, @rest) = @_;
		foreach my $r (@$rows) { push(@sent, "$r->[0]"); }
		return 1;
	};
	my $s1 = FakeBulkSTH->new(blocks => [[[1], [2]]], fail_at => 1, fail_err => 3113, fail_errstr => 'ORA-03113: first', fail_state => '');
	my $s2 = FakeBulkSTH->new(blocks => [[[3], [4]]], fail_at => 1, fail_err => 3113, fail_errstr => 'ORA-03113: second', fail_state => '');
	my $s3 = FakeBulkSTH->new(blocks => [[[5], [6]]]);
	my @sths = ($s1, $s2, $s3);
	my $k = 0;
	local *Ora2Pg::_src_prepare_source_sth = sub { $k++; return $sths[$k - 1]; };
	*FakeBulkSTH::execute = sub { return 1; };
	my $rc = 0;
	my @cps = ();
	local *Ora2Pg::_src_reconnect = sub {
		my ($self, $table, $phase, $diag, $cp) = @_;
		$rc++;
		push(@cps, defined $cp ? "$cp" : 'undef');
		return bless({}, 'FakeDBH2');
	};
	my $total = $o->_extract_resumable_bulk('SELECT a."ID" FROM "TW" a ORDER BY a."ID"', 'TW', [], [], 'X', ['ID'], ['bigint'], '', ['NUMBER'], undef, undef, {});
	is($total, 6, 'two failures still complete 6');
	is($rc, 2, 'two reconnects');
	is_deeply(\@cps, [qw(2 4)], 'checkpoints 2 then 4');
	is_deeply(\@sent, [qw(1 2 3 4 5 6)], 'no duplication across two resumes');
}

# --- 16. Checkpoint reset between tables ---
{
	my $o = make_obj(data_limit => 2);
	foreach my $t (qw(R1 R2)) {
		$o->{tables}{$t}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
		$o->{tables}{$t}{column_info} = { ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, $t, '', 'NO', 1] };
		$o->{tables}{$t}{table_info} = { num_rows => 2 };
		$o->{_src_resume}{$t} = {
			pk_idx => 0, pk_alias_quoted => 'a."ID"',
			base => "SELECT a.\"ID\" FROM \"$t\" a", has_where => 0, order => ' ORDER BY a."ID"',
		};
	}
	no warnings 'redefine';
	local *Ora2Pg::_dump_to_pg = sub { return 1; };
	*FakeBulkSTH::execute = sub { return 1; };
	my @seen_cp = ();
	local *Ora2Pg::_src_reconnect = sub {
		my ($self, $table, $phase, $diag, $cp) = @_;
		push(@seen_cp, [$table, defined $cp ? "$cp" : 'undef']);
		return bless({}, 'FakeDBH2');
	};
	# R1 fails before any confirmation -> cp undef.
	my $r1_done = 0;
	my $r2_done = 0;
	local *Ora2Pg::_src_prepare_source_sth = sub {
		my ($self, $table, $sql) = @_;
		if ($table eq 'R1' && !$r1_done) {
			$r1_done = 1;
			return FakeBulkSTH->new(fail_at => 0, fail_err => 3113, fail_errstr => 'ORA-03113: r1', fail_state => '');
		} elsif ($table eq 'R1') {
			return FakeBulkSTH->new(blocks => [[[1], [2]]]);
		} elsif ($table eq 'R2' && !$r2_done) {
			$r2_done = 1;
			return FakeBulkSTH->new(fail_at => 0, fail_err => 3113, fail_errstr => 'ORA-03113: r2', fail_state => '');
		} else {
			return FakeBulkSTH->new(blocks => [[[10], [20]]]);
		}
	};
	$o->{current_total_row} = 0;
	my $t1 = $o->_extract_resumable_bulk('SELECT a."ID" FROM "R1" a ORDER BY a."ID"', 'R1', [], [], 'X', ['ID'], ['bigint'], '', ['NUMBER'], undef, undef, {});
	my $t2 = $o->_extract_resumable_bulk('SELECT a."ID" FROM "R2" a ORDER BY a."ID"', 'R2', [], [], 'X', ['ID'], ['bigint'], '', ['NUMBER'], undef, undef, {});
	is($t1, 2, 'R1 total');
	is($t2, 2, 'R2 total');
	is(scalar(@seen_cp), 2, 'two reconnects across tables');
	is($seen_cp[0][0], 'R1', 'first reconnect for R1');
	is($seen_cp[0][1], 'undef', 'R1 checkpoint starts undef');
	is($seen_cp[1][0], 'R2', 'second reconnect for R2');
	is($seen_cp[1][1], 'undef', 'R2 checkpoint reset, not carrying R1');
	is($o->{current_total_row}, 4, 'global accumulates across tables without double count');
}

# --- 17. Non-resumable query has no ORDER BY (ordinary export unchanged) ---
{
	my $o = make_obj();
	$o->{tables}{NR}{unique_key} = { PK1 => { type => 'P', columns => ['ID', 'NAME'] } };
	$o->{tables}{NR}{column_info} = {
		ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'NR', '', 'NO', 1],
		NAME => ['NAME', 'VARCHAR2', 10, 'Y', undef, undef, undef, undef, 'NR', '', 'NO', 2],
	};
	$o->{tables}{NR}{table_info} = { nested => 'NO', owner => 'SC', num_rows => 5 };
	$o->{colinfo} = { NR => { ID => { nullable => 'N' }, NAME => { nullable => 'Y' } } };
	$o->{prefix} = 'DBA';
	$o->{data_type} = { NUMBER => 'numeric', VARCHAR2 => 'varchar' };
	$o->{user_type} = {};
	$o->{spatial_srid} = {};
	$o->{nullable} = {};
	$o->{local_data_limit} = {};
	$o->{bfile_found} = '';
	$o->{has_dbms_log_execute_privilege} = 0;
	$o->{empty_lob_null} = 0;
	$o->{enable_blob_export} = 1;
	$o->{enable_clob_export} = 1;
	$o->{trim_type} = 'BOTH';
	$o->{trim_char} = ' ';
	$o->{geometry_extract_type} = 'WKT';
	my $q = $o->_howto_get_data('NR', ['ID', 'NAME'], ['bigint', 'varchar'], ['NUMBER', 'VARCHAR2'], undef, undef);
	unlike($q, qr/ORDER BY/i, 'composite PK: no ORDER BY injected');
	ok(!exists $o->{_src_resume}{NR}, 'no resume template for fallback');
}

# --- 18. Repeated reconnect failures then success (session init per connection) ---
{
	my $o = make_obj();
	$o->{prefix} = 'DBA';
	$o->{user_grants} = 1;
	no warnings 'redefine';
	my $conns = 0;
	local *Ora2Pg::_db_connection = sub {
		my ($self) = @_;
		$conns++;
		if ($conns <= 2) {
			die "ORA2PG_SRC_RETRY:FATAL: ORA-03113: still down $conns\n";
		}
		$self->{prefix} = 'ALL';
		return bless({ prefix => 'ALL' }, 'FakeNewDBH');
	};
	my $died = '';
	my $dbh = undef;
	eval {
		local $ENV{ORA2PG_SRC_RETRY_NO_SLEEP} = 1;
		$dbh = $o->_src_reconnect('T', 'read', { err => 3113, errstr => 'ORA-03113: boom', state => '' }, '42');
		1;
	} or $died = $@;
	is($died, '', 'eventual success after repeated failures');
	is($conns, 3, 'three connections (2 fails + 1 success)');
	ok(defined $dbh, 'new handle returned');
	is($o->{prefix}, 'ALL', 'prefix ALL preserved with USER_GRANTS=1');
}

# --- 19. Oracle LOB failure discards block, no NULL/truncate, then resumes ---
{
	my $o = make_obj(data_limit => 2);
	$o->{tables}{LT}{unique_key} = { PK1 => { type => 'P', columns => ['ID'] } };
	$o->{tables}{LT}{column_info} = {
		ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'LT', '', 'NO', 1],
		DATA => ['DATA', 'CLOB', 4000, 'Y', undef, undef, undef, undef, 'LT', '', 'NO', 2],
	};
	$o->{tables}{LT}{table_info} = { num_rows => 3 };
	$o->{_src_resume}{LT} = {
		pk_idx => 0, pk_alias_quoted => 'a."ID"',
		base => 'SELECT a."ID", a."DATA" FROM "LT" a', has_where => 0, order => ' ORDER BY a."ID"',
	};
	$o->{dbh} = FakeOracleDBH->new(fail_loc => 'LOC2');
	no warnings 'redefine';
	my @sent = ();
	local *Ora2Pg::_dump_to_pg = sub {
		my ($self, $proc, $rows, @rest) = @_;
		foreach my $r (@$rows) {
			push(@sent, ["$r->[0]", defined $r->[1] ? "$r->[1]" : undef]);
		}
		return 1;
	};
	my $s1 = FakeRowSTH->new(rows => [[1, 'LOC1'], [2, 'LOC2']]);
	my $s2 = FakeRowSTH->new(rows => [[1, 'LOC1'], [2, 'LOC2'], [3, 'LOC3']]);
	my @sths = ($s1, $s2);
	my $k = 0;
	local *Ora2Pg::_src_prepare_source_sth = sub { $k++; return $sths[$k - 1]; };
	my $rc = 0;
	local *Ora2Pg::_src_reconnect = sub {
		my ($self, $table, $phase, $diag, $cp) = @_;
		$rc++;
		like($diag->{errstr} || '', qr/ORA-03113/, 'lob diagnosis preserved');
		# New session without programmed failure.
		$self->{dbh} = FakeOracleDBH->new();
		return $self->{dbh};
	};
	my $total = $o->_extract_resumable_lob('SELECT a."ID", a."DATA" FROM "LT" a ORDER BY a."ID"', 'LT', [], [], 'X', ['ID', 'DATA'], ['bigint', 'text'], '', ['NUMBER', 'CLOB'], undef, undef, {});
	is($total, 3, 'lob resume completes 3');
	is($rc, 1, 'one reconnect for lob failure');
	is(scalar(@sent), 3, 'three rows sent, failed block discarded not NULLed');
	is($sent[0][0], '1', 'first id');
	is($sent[0][1], 'CONTENT-LOC1', 'lob content intact, not truncated');
	is($sent[1][0], '2', 'second id after resume');
	is($sent[1][1], 'CONTENT-LOC2', 'retried lob content intact');
	is($sent[2][0], '3', 'third id');
	my $null_lobs = grep { !defined $_->[1] } @sent;
	ok($null_lobs == 0, 'no NULL from lob error');
}

# --- 20. Ordinary (non-resumable) export unchanged when no errors ---
{
	my $o = make_obj(data_limit => 2, pg_dsn => undef);
	$o->{tables}{ORD}{unique_key} = {};
	$o->{tables}{ORD}{column_info} = {
		ID => ['ID', 'NUMBER', 22, 'N', undef, undef, undef, undef, 'ORD', '', 'NO', 1],
	};
	$o->{tables}{ORD}{table_info} = { num_rows => 2, nested => 'NO', owner => 'SC' };
	$o->{colinfo} = { ORD => { ID => { nullable => 'N' } } };
	$o->{prefix} = 'DBA';
	$o->{data_type} = { NUMBER => 'numeric' };
	$o->{user_type} = {};
	$o->{spatial_srid} = {};
	$o->{nullable} = {};
	$o->{local_data_limit} = {};
	$o->{bfile_found} = '';
	$o->{has_dbms_log_execute_privilege} = 0;
	$o->{empty_lob_null} = 0;
	$o->{enable_blob_export} = 1;
	$o->{enable_clob_export} = 1;
	$o->{trim_type} = 'BOTH';
	$o->{trim_char} = ' ';
	$o->{geometry_extract_type} = 'WKT';
	# No resume expected.
	my $q = $o->_howto_get_data('ORD', ['ID'], ['bigint'], ['NUMBER'], undef, undef);
	unlike($q, qr/ORDER BY/i, 'ordinary query without ORDER BY');
	ok(!exists $o->{_src_resume}{ORD}, 'no resume for ordinary table');
}

done_testing();
