implement Llmfs;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, Navop, Fid: import styxservers;
	Ebadfid, Enotfound, Eperm, Ebadarg: import styxservers;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "mhttp.m";
	http: Http;
	Url, Hdrs, Req, Resp: import http;
include "json.m";
	json: JSON;
	JValue: import json;
include "arg.m";
include "string.m";
	str: String;

Llmfs: module {
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

# File types encoded in low 4 bits of QID path.
# Must fit in 4 bits (16 max).
Qroot, Qclone, Qinfo,
Qdir, Qctl, Qdata, Qstatus,
Qsystem, Qtools, Qtoolchoice,
Qmessages, Qmsgclone, Qmsg,
Qmrole, Qmcontent, Qmname: con iota;

# These don't fit in 4 bits, so we encode them with a special trick:
# the per-message scalar files share the Qmsg space; we distinguish
# them by the file name in the path. To keep things simple and within
# 4 bits, we shift to 5 bits for type. Path layout:
#   bits 0-4   type (5 bits, 32 max)
#   bits 5-16  conn idx (12 bits, 4096 max)
#   bits 17-28 turn idx (12 bits, 4096 max)
#   bits 29+   pathgen (uniqueness)
Qmtoolcallid, Qmtoolcalls, Qmfinish: con iota + Qmname + 1;

# Top-level connfiles (per-conn directory)
connfiles := array[] of {
	(Qctl, "ctl"),
	(Qdata, "data"),
	(Qstatus, "status"),
	(Qsystem, "system"),
	(Qtools, "tools"),
	(Qtoolchoice, "tool_choice"),
	(Qmessages, "messages"),
};

# Per-message scalar files
msgfiles := array[] of {
	(Qmrole, "role"),
	(Qmcontent, "content"),
	(Qmname, "name"),
	(Qmtoolcallid, "tool_call_id"),
	(Qmtoolcalls, "tool_calls"),
	(Qmfinish, "finish_reason"),
};

# Connection states
Idle, Prompting, Generating, Done: con iota;
statenames := array[] of { "Idle", "Prompting", "Generating", "Done" };

# Modes for outstanding API calls
Mdata, Mchat: con iota;

Msg: adt {
	role:		string;	# user|assistant|developer|tool
	content:	string;
	mname:		string;	# optional name field
	tool_call_id:	string;	# for role=tool
	tool_calls:	string;	# JSON array text, set by API for assistant
	finish_reason:	string;	# set by API for assistant
};

LlmConn: adt {
	id:		int;
	x:		int;		# slot index in conns array
	path:		big;		# base path (no type, no turnidx)
	state:		int;
	mode:		int;		# Mdata or Mchat for in-flight call
	model:		string;
	system_prompt:	string;
	tools_md:	string;
	tool_choice:	string;
	transform:	int;		# 1=enable middle-out
	data_prompt:	string;
	output:		string;		# data-mode result
	outerr:		string;
	temp:		real;
	top_p:		real;
	max_tokens:	int;
	seed:		int;
	messages:	array of ref Msg;	# nils allowed (gaps)
};

# Snapshot passed to apicall goroutine; built under serveloop ownership
Snap: adt {
	connx:		int;
	mode:		int;
	model:		string;
	system_prompt:	string;
	tools_md:	string;
	tool_choice:	string;
	transform:	int;
	data_prompt:	string;
	temp:		real;
	top_p:		real;
	max_tokens:	int;
	seed:		int;
	messages:	array of ref Msg;	# deep-copied
};

ApiResult: adt {
	connx:		int;
	mode:		int;
	content:	string;
	tool_calls:	string;
	finish_reason:	string;
	err:		string;
};

PendingRead: adt {
	tag:	int;
	offset:	big;
	count:	int;
	connx:	int;
	qtype:	int;	# Qdata, Qmcontent, Qmtoolcalls, Qmfinish, ...
	turnix:	int;	# turn index (Mchat); ignored for Mdata
};

conns:		array of ref LlmConn;
next_conn_id :=	1;
pathgen :=	0;
default_model :=	"openai/gpt-4.1-nano";
apikey:		string;
apich:		chan of ref ApiResult;
user:		string;
model_info:	string;

# Bit layout for path:
#   [4:0]    type    (5 bits)
#   [16:5]   connidx (12 bits)
#   [28:17]  turnidx (12 bits)
#   [..29]   pathgen (uniqueness)
TYPEBITS:	con 5;
TYPEMASK:	con 16r1F;
CONNBITS:	con 12;
CONNSHIFT:	con TYPEBITS;
CONNMASK:	con (1 << CONNBITS) - 1;
TURNBITS:	con 12;
TURNSHIFT:	con CONNSHIFT + CONNBITS;
TURNMASK:	con (1 << TURNBITS) - 1;
GENSHIFT:	con TURNSHIFT + TURNBITS;

nomod(path: string)
{
	sys->fprint(sys->fildes(2), "llmfs: cannot load %s: %r\n", path);
	raise "fail:load";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->NEWPGRP, nil);

	bufio = load Bufio Bufio->PATH;
	if(bufio == nil) nomod(Bufio->PATH);
	styx = load Styx Styx->PATH;
	if(styx == nil) nomod(Styx->PATH);
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil) nomod(Styxservers->PATH);
	http = load Http Http->PATH;
	if(http == nil) nomod(Http->PATH);
	json = load JSON JSON->PATH;
	if(json == nil) nomod(JSON->PATH);
	str = load String String->PATH;
	if(str == nil) nomod(String->PATH);

	styx->init();
	styxservers->init(styx);
	http->init(bufio);
	json->init(bufio);

	sys->bind("#T", "/dev", Sys->MAFTER);

	arg := load Arg Arg->PATH;
	if(arg == nil) nomod(Arg->PATH);
	arg->init(args);
	arg->setusage("llmfs [-D] [-m mntpt] [-k apikey] [-M model]");
	mountpt := "/n/llm";
	while((o := arg->opt()) != 0)
		case o {
		'm' =>	mountpt = arg->earg();
		'D' =>	styxservers->traceset(1);
		'k' =>	apikey = arg->earg();
		'M' =>	default_model = arg->earg();
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();

	if(apikey == nil) {
		apikey = readfile("/env/OPENROUTER_API_KEY");
		if(apikey == nil) {
			sys->fprint(sys->fildes(2), "llmfs: no API key: use -k or set OPENROUTER_API_KEY\n");
			raise "fail:no key";
		}
	}

	user = readfile("/dev/user");
	if(user == nil)
		user = "llmfs";

	model_info = fetchmodelinfo(default_model);

	conns = array[16] of ref LlmConn;
	apich = chan of ref ApiResult;

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0) {
		sys->fprint(sys->fildes(2), "llmfs: pipe: %r\n");
		raise "fail:pipe";
	}

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	fds[0] = nil;

	pidc := chan of int;
	spawn serveloop(tchan, srv, pidc, navops);
	<-pidc;

	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL|Sys->MCREATE, nil) < 0) {
		sys->fprint(sys->fildes(2), "llmfs: mount on %s: %r\n", mountpt);
		raise "fail:mount";
	}
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	s := string buf[0:n];
	# strip trailing whitespace/newlines
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' ' || s[len s - 1] == '\t'))
		s = s[:len s - 1];
	return s;
}

# QID path encoding
TYPE(path: big): int
{
	return int (path & big TYPEMASK);
}

INDEX(path: big): int
{
	return int ((path >> CONNSHIFT) & big CONNMASK);
}

SUBINDEX(path: big): int
{
	return int ((path >> TURNSHIFT) & big TURNMASK);
}

# strip type field (preserve conn+turn+gen)
basepath(path: big): big
{
	return path & ~big TYPEMASK;
}

# strip type and turn fields (preserve conn+gen)
connbase(path: big): big
{
	return path & ~big ((TURNMASK << TURNSHIFT) | TYPEMASK);
}

mkpath(cb: big, turnix: int, qt: int): big
{
	return cb | (big turnix << TURNSHIFT) | big qt;
}

findconn(path: big): ref LlmConn
{
	i := INDEX(path);
	if(i < 0 || i >= len conns)
		return nil;
	c := conns[i];
	if(c == nil)
		return nil;
	if(connbase(c.path) != connbase(path))
		return nil;
	return c;
}

findconnid(id: int): ref LlmConn
{
	for(i := 0; i < len conns; i++)
		if((c := conns[i]) != nil && c.id == id)
			return c;
	return nil;
}

newconn(): ref LlmConn
{
	i: int;
	for(i = 0; i < len conns; i++)
		if(conns[i] == nil)
			break;
	if(i >= len conns) {
		nc := array[len conns + 16] of ref LlmConn;
		nc[0:] = conns;
		conns = nc;
	}
	id := next_conn_id++;
	# pathgen contributes uniqueness across conn-slot reuse.
	cb := (big pathgen++ << GENSHIFT) | (big i << CONNSHIFT);
	c := ref LlmConn(
		id, i, cb, Idle, Mdata,
		default_model,
		"", "", "", 1,	# system, tools_md, tool_choice, transform
		"", "", nil,	# data_prompt, output, outerr
		1.0, 0.9,	# temp, top_p
		-1, -1,		# max_tokens, seed
		nil		# messages
	);
	conns[i] = c;
	return c;
}

freeconn(c: ref LlmConn)
{
	if(c != nil && c.x < len conns)
		conns[c.x] = nil;
}

# allocate next free turn slot in conn.messages, return its index
newturn(c: ref LlmConn): int
{
	i: int;
	for(i = 0; i < len c.messages; i++)
		if(c.messages[i] == nil)
			break;
	if(i >= len c.messages) {
		nm := array[len c.messages + 8] of ref Msg;
		nm[0:] = c.messages;
		c.messages = nm;
	}
	c.messages[i] = ref Msg("", "", "", "", "", "");
	return i;
}

# Return mode and length for a per-message scalar file.
msgfilemode(qtype: int): (int, int)
{
	case qtype {
	Qmcontent or Qmrole or Qmname or Qmtoolcallid =>
		return (8r666, 0);
	Qmtoolcalls or Qmfinish =>
		return (8r444, 0);
	}
	return (8r666, 0);
}

# Dir entry generation.
# For per-conn files (Qctl, Qdata, Qstatus, Qsystem, ...) the path
# carries the conn base; turnix bits are ignored.
# For per-message files the path carries conn base | turnix | type.
dirgen(p: big, name: string, c: ref LlmConn): (ref Sys->Dir, string)
{
	t := TYPE(p);
	case t {
	Qroot =>
		return (mkdir(Sys->Qid(big Qroot, 0, Sys->QTDIR), ".", big 0, 8r755), nil);
	Qclone =>
		return (mkdir(Sys->Qid(big Qclone, 0, Sys->QTFILE), "clone", big 0, 8r666), nil);
	Qinfo =>
		return (mkdir(Sys->Qid(big Qinfo, 0, Sys->QTFILE), "info", big 0, 8r444), nil);
	Qdir =>
		if(c == nil) {
			c = findconn(p);
			if(c == nil)
				return (nil, Enotfound);
		}
		nm := name;
		if(nm == nil)
			nm = string c.id;
		return (mkdir(Sys->Qid(p, 0, Sys->QTDIR), nm, big 0, 8r755), nil);
	Qctl =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "ctl", big 0, 8r666), nil);
	Qdata =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "data", big 0, 8r666), nil);
	Qstatus =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "status", big 0, 8r444), nil);
	Qsystem =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "system", big 0, 8r666), nil);
	Qtools =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "tools", big 0, 8r666), nil);
	Qtoolchoice =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "tool_choice", big 0, 8r666), nil);
	Qmessages =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTDIR), "messages", big 0, 8r755), nil);
	Qmsgclone =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "clone", big 0, 8r666), nil);
	Qmsg =>
		nm := name;
		if(nm == nil)
			nm = string SUBINDEX(p);
		return (mkdir(Sys->Qid(p, 0, Sys->QTDIR), nm, big 0, 8r755), nil);
	Qmrole =>
		(m, nil) := msgfilemode(t);
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "role", big 0, m), nil);
	Qmcontent =>
		(m, nil) := msgfilemode(t);
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "content", big 0, m), nil);
	Qmname =>
		(m, nil) := msgfilemode(t);
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "name", big 0, m), nil);
	Qmtoolcallid =>
		(m, nil) := msgfilemode(t);
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "tool_call_id", big 0, m), nil);
	Qmtoolcalls =>
		(m, nil) := msgfilemode(t);
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "tool_calls", big 0, m), nil);
	Qmfinish =>
		(m, nil) := msgfilemode(t);
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "finish_reason", big 0, m), nil);
	}
	return (nil, Enotfound);
}

mkdir(qid: Sys->Qid, name: string, length: big, perm: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.qid = qid;
	if(qid.qtype & Sys->QTDIR)
		perm |= Sys->DMDIR;
	d.mode = perm;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.length = length;
	return d;
}

# Navigator goroutine
navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
	   Pick:
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path, nil, nil);
		Walk =>
			t := TYPE(n.path);
			case t {
			Qroot =>
				if(n.name == "..") {
					n.reply <-= dirgen(big Qroot, nil, nil);
					break;
				}
				if(n.name == "clone") {
					n.reply <-= dirgen(big Qclone, nil, nil);
					break;
				}
				if(n.name == "info") {
					n.reply <-= dirgen(big Qinfo, nil, nil);
					break;
				}
				id := int n.name;
				if(id > 0 && string id == n.name) {
					c := findconnid(id);
					if(c != nil) {
						n.reply <-= dirgen(c.path | big Qdir, n.name, c);
						break;
					}
				}
				n.reply <-= (nil, Enotfound);
			Qdir =>
				if(n.name == "..") {
					n.reply <-= dirgen(big Qroot, nil, nil);
					break;
				}
				cb := connbase(n.path);
				for(j := 0; j < len connfiles; j++) {
					(ftype, fname) := connfiles[j];
					if(n.name == fname) {
						n.reply <-= dirgen(cb | big ftype, fname, nil);
						break Pick;
					}
				}
				n.reply <-= (nil, Enotfound);
			Qmessages =>
				if(n.name == "..") {
					n.reply <-= dirgen(connbase(n.path) | big Qdir, nil, nil);
					break;
				}
				if(n.name == "clone") {
					n.reply <-= dirgen(connbase(n.path) | big Qmsgclone, nil, nil);
					break;
				}
				idx := int n.name;
				if(idx >= 0 && string idx == n.name) {
					c := findconn(n.path);
					if(c != nil) {
						if(idx < len c.messages && c.messages[idx] != nil) {
							p := mkpath(connbase(n.path), idx, Qmsg);
							n.reply <-= dirgen(p, n.name, c);
							break;
						}
						# Allow walking to a not-yet-existing slot
						# during a Generating chat call so reads on
						# its scalar files can block. The slot may
						# be a nil hole within the array (capacity
						# is grown in chunks) or just past the end.
						if(c.state == Generating && c.mode == Mchat) {
							p := mkpath(connbase(n.path), idx, Qmsg);
							n.reply <-= dirgen(p, n.name, c);
							break;
						}
					}
				}
				n.reply <-= (nil, Enotfound);
			Qmsg =>
				if(n.name == "..") {
					n.reply <-= dirgen(connbase(n.path) | big Qmessages, nil, nil);
					break;
				}
				cb := connbase(n.path);
				ti := SUBINDEX(n.path);
				for(j := 0; j < len msgfiles; j++) {
					(ftype, fname) := msgfiles[j];
					if(n.name == fname) {
						n.reply <-= dirgen(mkpath(cb, ti, ftype), fname, nil);
						break Pick;
					}
				}
				n.reply <-= (nil, Enotfound);
			Qctl or Qdata or Qstatus or Qsystem or Qtools or Qtoolchoice =>
				if(n.name == "..") {
					n.reply <-= dirgen(connbase(n.path) | big Qdir, nil, nil);
					break;
				}
				n.reply <-= (nil, Enotfound);
			Qmsgclone =>
				if(n.name == "..") {
					n.reply <-= dirgen(connbase(n.path) | big Qmessages, nil, nil);
					break;
				}
				n.reply <-= (nil, Enotfound);
			Qmrole or Qmcontent or Qmname or Qmtoolcallid or Qmtoolcalls or Qmfinish =>
				if(n.name == "..") {
					cb := connbase(n.path);
					ti := SUBINDEX(n.path);
					n.reply <-= dirgen(mkpath(cb, ti, Qmsg), nil, nil);
					break;
				}
				n.reply <-= (nil, Enotfound);
			* =>
				n.reply <-= (nil, Enotfound);
			}
		Readdir =>
			t := TYPE(n.path);
			case t {
			Qroot =>
				slot := 0;
				count := n.count;
				off := n.offset;
				if(slot >= off && count > 0) {
					n.reply <-= dirgen(big Qclone, nil, nil);
					count--;
				}
				slot++;
				if(slot >= off && count > 0) {
					n.reply <-= dirgen(big Qinfo, nil, nil);
					count--;
				}
				slot++;
				for(j := 0; j < len conns && count > 0; j++) {
					cc := conns[j];
					if(cc == nil)
						continue;
					if(slot >= off) {
						n.reply <-= dirgen(cc.path | big Qdir, string cc.id, cc);
						count--;
					}
					slot++;
				}
				n.reply <-= (nil, nil);
			Qdir =>
				cb := connbase(n.path);
				count := n.count;
				for(j := n.offset; count > 0 && j < len connfiles; j++) {
					(ftype, fname) := connfiles[j];
					n.reply <-= dirgen(cb | big ftype, fname, nil);
					count--;
				}
				n.reply <-= (nil, nil);
			Qmessages =>
				cb := connbase(n.path);
				cc := findconn(n.path);
				count := n.count;
				slot := 0;
				# entry 0: clone
				if(slot >= n.offset && count > 0) {
					n.reply <-= dirgen(cb | big Qmsgclone, nil, nil);
					count--;
				}
				slot++;
				if(cc != nil) {
					for(j := 0; j < len cc.messages && count > 0; j++) {
						if(cc.messages[j] == nil)
							continue;
						if(slot >= n.offset) {
							p := mkpath(cb, j, Qmsg);
							n.reply <-= dirgen(p, string j, cc);
							count--;
						}
						slot++;
					}
				}
				n.reply <-= (nil, nil);
			Qmsg =>
				cb := connbase(n.path);
				ti := SUBINDEX(n.path);
				count := n.count;
				for(j := n.offset; count > 0 && j < len msgfiles; j++) {
					(ftype, fname) := msgfiles[j];
					n.reply <-= dirgen(mkpath(cb, ti, ftype), fname, nil);
					count--;
				}
				n.reply <-= (nil, nil);
			* =>
				n.reply <-= (nil, nil);
			}
		}
	}
}

# build a deep-copy snapshot of the conn for use by the API goroutine.
snapshot(c: ref LlmConn, mode: int): ref Snap
{
	s := ref Snap;
	s.connx = c.x;
	s.mode = mode;
	s.model = c.model;
	s.system_prompt = c.system_prompt;
	s.tools_md = c.tools_md;
	s.tool_choice = c.tool_choice;
	s.transform = c.transform;
	s.data_prompt = c.data_prompt;
	s.temp = c.temp;
	s.top_p = c.top_p;
	s.max_tokens = c.max_tokens;
	s.seed = c.seed;
	if(mode == Mchat && len c.messages > 0) {
		nm := array[len c.messages] of ref Msg;
		for(j := 0; j < len c.messages; j++) {
			if(c.messages[j] != nil) {
				m := *c.messages[j];
				nm[j] = ref m;
			}
		}
		s.messages = nm;
	}
	return s;
}

# Main serve loop
serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver, pidc: chan of int,
	  navops: chan of ref Navop)
{
	pidc <-= sys->pctl(Sys->FORKNS|Sys->NEWFD, 1 :: 2 :: srv.fd.fd :: nil);
	pending: list of ref PendingRead;

	for(;;) alt {
	gm := <-tchan =>
		if(gm == nil) {
			navops <-= nil;
			return;
		}
		pick m := gm {
		Open =>
			(c, mode, nil, err) := srv.canopen(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			case TYPE(c.path) {
			Qclone =>
				conn := newconn();
				c.data = array of byte string conn.id;
				# point this fid at the new conn's ctl path so future
				# reads of the clone fid return the conn id
				c.open(mode, Sys->Qid(c.path, 0, Sys->QTFILE));
				srv.reply(ref Rmsg.Open(m.tag, Sys->Qid(c.path, 0, Sys->QTFILE), srv.iounit()));
			Qmsgclone =>
				conn := findconn(c.path);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				idx := newturn(conn);
				c.data = array of byte string idx;
				c.open(mode, Sys->Qid(c.path, 0, Sys->QTFILE));
				srv.reply(ref Rmsg.Open(m.tag, Sys->Qid(c.path, 0, Sys->QTFILE), srv.iounit()));
			* =>
				srv.open(m);
			}
		Read =>
			(c, err) := srv.canread(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(c.qtype & Sys->QTDIR) {
				srv.read(m);
				break;
			}
			t := TYPE(c.path);
			case t {
			Qclone =>
				srv.reply(styxservers->readbytes(m, c.data));
			Qinfo =>
				srv.reply(styxservers->readstr(m, model_info));
			Qmsgclone =>
				srv.reply(styxservers->readbytes(m, c.data));
			Qctl =>
				conn := findconn(c.path);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readstr(m, string conn.id));
			Qstatus =>
				conn := findconn(c.path);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readstr(m, statenames[conn.state]));
			Qsystem =>
				conn := findconn(c.path);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readstr(m, conn.system_prompt));
			Qtools =>
				conn := findconn(c.path);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readstr(m, conn.tools_md));
			Qtoolchoice =>
				conn := findconn(c.path);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readstr(m, conn.tool_choice));
			Qdata =>
				conn := findconn(c.path);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(conn.state == Generating && conn.mode == Mdata) {
					pending = ref PendingRead(m.tag, m.offset, m.count, conn.x, Qdata, 0) :: pending;
					break;
				}
				if(conn.state == Done && conn.mode == Mdata) {
					if(conn.outerr != nil) {
						srv.reply(ref Rmsg.Error(m.tag, conn.outerr));
						break;
					}
					srv.reply(styxservers->readstr(m, conn.output));
				} else
					srv.reply(styxservers->readstr(m, ""));
			Qmrole or Qmcontent or Qmname or Qmtoolcallid or Qmtoolcalls or Qmfinish =>
				conn := findconn(c.path);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				ti := SUBINDEX(c.path);
				# block read on a not-yet-filled slot during a
				# Generating chat call (the assistant turn
				# apicall will write into).
				if(ti >= len conn.messages || conn.messages[ti] == nil) {
					if(conn.state == Generating && conn.mode == Mchat) {
						pending = ref PendingRead(m.tag, m.offset, m.count, conn.x, t, ti) :: pending;
						break;
					}
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readstr(m, msgreadfield(conn.messages[ti], t)));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}
		Write =>
			(c, err) := srv.canwrite(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			conn := findconn(c.path);
			tt := TYPE(c.path);
			if(conn == nil && tt != Qclone && tt != Qinfo) {
				srv.reply(ref Rmsg.Error(m.tag, Enotfound));
				break;
			}
			case tt {
			Qctl =>
				cerr := parsectl(conn, string m.data);
				if(cerr != nil) {
					srv.reply(ref Rmsg.Error(m.tag, cerr));
					break;
				}
				if(conn.state == Prompting && conn.mode == Mchat) {
					# ctl send: snapshot and spawn
					conn.state = Generating;
					snap := snapshot(conn, Mchat);
					spawn apicall(snap);
				}
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qdata =>
				if(m.offset == big 0)
					conn.data_prompt = "";
				conn.data_prompt += string m.data;
				conn.state = Prompting;
				conn.mode = Mdata;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qsystem =>
				if(m.offset == big 0)
					conn.system_prompt = "";
				conn.system_prompt += string m.data;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qtools =>
				if(m.offset == big 0)
					conn.tools_md = "";
				conn.tools_md += string m.data;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qtoolchoice =>
				if(m.offset == big 0)
					conn.tool_choice = "";
				conn.tool_choice += string m.data;
				# trim trailing newline
				while(len conn.tool_choice > 0 && conn.tool_choice[len conn.tool_choice - 1] == '\n')
					conn.tool_choice = conn.tool_choice[:len conn.tool_choice - 1];
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qmrole or Qmcontent or Qmname or Qmtoolcallid =>
				ti := SUBINDEX(c.path);
				if(ti >= len conn.messages || conn.messages[ti] == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(tt == Qmtoolcallid && conn.messages[ti].role == nil)
					conn.messages[ti].role = "tool";
				msgwritefield(conn.messages[ti], tt, m.offset, string m.data);
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qmtoolcalls or Qmfinish =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}
		Clunk =>
			c := srv.clunk(m);
			if(c == nil)
				break;
			# Closing a writer on data triggers generation (one-shot mode).
			if(c.isopen && (c.mode & 3) != Styx->OREAD) {
				conn := findconn(c.path);
				if(conn != nil && conn.state == Prompting && conn.mode == Mdata) {
					case TYPE(c.path) {
					Qdata =>
						conn.state = Generating;
						conn.output = "";
						conn.outerr = nil;
						snap := snapshot(conn, Mdata);
						spawn apicall(snap);
					}
				}
			}
		Remove =>
			(c, qpath, rerr) := srv.canremove(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, rerr));
				break;
			}
			tt := TYPE(qpath);
			if(tt != Qmsg) {
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
				break;
			}
			conn := findconn(qpath);
			if(conn == nil) {
				srv.reply(ref Rmsg.Error(m.tag, Enotfound));
				break;
			}
			ti := SUBINDEX(qpath);
			if(ti >= len conn.messages || conn.messages[ti] == nil) {
				srv.reply(ref Rmsg.Error(m.tag, Enotfound));
				break;
			}
			conn.messages[ti] = nil;
			srv.delfid(c);
			srv.reply(ref Rmsg.Remove(m.tag));
		Flush =>
			newp: list of ref PendingRead;
			for(pl := pending; pl != nil; pl = tl pl) {
				pr := hd pl;
				if(pr.tag != m.oldtag)
					newp = pr :: newp;
			}
			pending = newp;
			srv.default(gm);
		* =>
			srv.default(gm);
		}
	ar := <-apich =>
		if(ar.connx >= len conns || conns[ar.connx] == nil)
			break;
		c := conns[ar.connx];
		newturnix := -1;
		if(ar.mode == Mchat) {
			# Append assistant turn (or error sentinel turn) to messages.
			ti := newturn(c);
			newturnix = ti;
			c.messages[ti].role = "assistant";
			if(ar.err != nil) {
				c.messages[ti].content = "";
				c.messages[ti].finish_reason = "error";
				# Stash error so blocked reads see it
				c.outerr = ar.err;
			} else {
				c.messages[ti].content = ar.content;
				c.messages[ti].tool_calls = ar.tool_calls;
				c.messages[ti].finish_reason = ar.finish_reason;
				c.outerr = nil;
			}
		} else {
			if(ar.err != nil) {
				c.outerr = ar.err;
				c.output = "";
			} else {
				c.output = ar.content;
				c.outerr = nil;
			}
		}
		c.state = Done;
		# satisfy pending reads for this conn
		newp: list of ref PendingRead;
		for(pl := pending; pl != nil; pl = tl pl) {
			pr := hd pl;
			if(pr.connx != ar.connx) {
				newp = pr :: newp;
				continue;
			}
			if(ar.mode == Mdata && pr.qtype == Qdata) {
				replyreaddata(srv, pr, c);
			} else if(ar.mode == Mchat && newturnix >= 0) {
				replyreadmsg(srv, pr, c, newturnix);
			} else {
				newp = pr :: newp;
			}
		}
		pending = newp;
	}
}

# Read one of the per-message scalar fields.
msgreadfield(m: ref Msg, qtype: int): string
{
	case qtype {
	Qmrole =>		return m.role;
	Qmcontent =>		return m.content;
	Qmname =>		return m.mname;
	Qmtoolcallid =>		return m.tool_call_id;
	Qmtoolcalls =>		return m.tool_calls;
	Qmfinish =>		return m.finish_reason;
	}
	return "";
}

# Write one of the per-message R/W scalar fields.
msgwritefield(m: ref Msg, qtype: int, offset: big, data: string)
{
	case qtype {
	Qmrole =>
		if(offset == big 0)
			m.role = "";
		m.role += data;
		# trim trailing newline
		while(len m.role > 0 && m.role[len m.role - 1] == '\n')
			m.role = m.role[:len m.role - 1];
	Qmcontent =>
		if(offset == big 0)
			m.content = "";
		m.content += data;
	Qmname =>
		if(offset == big 0)
			m.mname = "";
		m.mname += data;
		while(len m.mname > 0 && m.mname[len m.mname - 1] == '\n')
			m.mname = m.mname[:len m.mname - 1];
	Qmtoolcallid =>
		if(offset == big 0)
			m.tool_call_id = "";
		m.tool_call_id += data;
		while(len m.tool_call_id > 0 && m.tool_call_id[len m.tool_call_id - 1] == '\n')
			m.tool_call_id = m.tool_call_id[:len m.tool_call_id - 1];
	}
}

replyreaddata(srv: ref Styxserver, pr: ref PendingRead, conn: ref LlmConn)
{
	if(conn.outerr != nil) {
		srv.reply(ref Rmsg.Error(pr.tag, conn.outerr));
		return;
	}
	data := array of byte conn.output;
	off := int pr.offset;
	if(off >= len data) {
		srv.reply(ref Rmsg.Read(pr.tag, array[0] of byte));
		return;
	}
	end := off + pr.count;
	if(end > len data)
		end = len data;
	srv.reply(ref Rmsg.Read(pr.tag, data[off:end]));
}

replyreadmsg(srv: ref Styxserver, pr: ref PendingRead, conn: ref LlmConn, ti: int)
{
	if(conn.outerr != nil) {
		srv.reply(ref Rmsg.Error(pr.tag, conn.outerr));
		return;
	}
	if(ti >= len conn.messages || conn.messages[ti] == nil) {
		srv.reply(ref Rmsg.Error(pr.tag, Enotfound));
		return;
	}
	s := msgreadfield(conn.messages[ti], pr.qtype);
	data := array of byte s;
	off := int pr.offset;
	if(off >= len data) {
		srv.reply(ref Rmsg.Read(pr.tag, array[0] of byte));
		return;
	}
	end := off + pr.count;
	if(end > len data)
		end = len data;
	srv.reply(ref Rmsg.Read(pr.tag, data[off:end]));
}

parsectl(conn: ref LlmConn, cmd: string): string
{
	(n, toks) := sys->tokenize(cmd, " \t\n");
	if(n < 1)
		return Ebadarg;
	verb := hd toks;
	rest := tl toks;
	case verb {
	"temp" =>
		if(n < 2) return Ebadarg;
		conn.temp = real hd rest;
	"top" =>
		if(n < 2) return Ebadarg;
		conn.top_p = real hd rest;
	"max_tokens" =>
		if(n < 2) return Ebadarg;
		conn.max_tokens = int hd rest;
	"seed" =>
		if(n < 2) return Ebadarg;
		conn.seed = int hd rest;
	"mode" =>
		;	# accept but ignore for API mode
	"model" =>
		if(n < 2) return Ebadarg;
		conn.model = hd rest;
	"tool_choice" =>
		if(n < 2) return Ebadarg;
		conn.tool_choice = hd rest;
	"transform" =>
		if(n < 2) return Ebadarg;
		case hd rest {
		"on" =>		conn.transform = 1;
		"off" =>	conn.transform = 0;
		* =>		return Ebadarg;
		}
	"send" =>
		if(conn.state == Generating)
			return "busy";
		# count non-nil messages
		nm := 0;
		for(j := 0; j < len conn.messages; j++)
			if(conn.messages[j] != nil)
				nm++;
		if(nm == 0 && conn.system_prompt == "")
			return "no messages";
		conn.mode = Mchat;
		conn.state = Prompting;
		# Caller (Qctl write) will fire apicall after parsectl returns
		# because state==Prompting && mode==Mchat.
	"cancel" =>
		if(conn.state != Generating)
			return "not generating";
		# Best-effort: mark idle. Goroutine will still post a result;
		# the apich handler discards it because state==Idle.
		conn.state = Idle;
		conn.outerr = "cancelled";
	"trim" =>
		if(n < 2) return Ebadarg;
		case hd rest {
		"keep" =>
			if(n < 3) return Ebadarg;
			k := int hd tl rest;
			trimkeep(conn, k);
		* =>
			ndrop := int hd rest;
			trimoldest(conn, ndrop);
		}
	"reset" =>
		conn.state = Idle;
		conn.mode = Mdata;
		conn.system_prompt = "";
		conn.tools_md = "";
		conn.tool_choice = "";
		conn.data_prompt = "";
		conn.output = "";
		conn.outerr = "";
		conn.messages = nil;
	* =>
		return "unknown ctl command";
	}
	return nil;
}

# Drop the n oldest non-nil messages.
trimoldest(conn: ref LlmConn, n: int)
{
	for(j := 0; j < len conn.messages && n > 0; j++) {
		if(conn.messages[j] != nil) {
			conn.messages[j] = nil;
			n--;
		}
	}
}

# Drop oldest until at most k messages remain.
trimkeep(conn: ref LlmConn, k: int)
{
	live := 0;
	for(j := 0; j < len conn.messages; j++)
		if(conn.messages[j] != nil)
			live++;
	if(live <= k)
		return;
	trimoldest(conn, live - k);
}

# Build one ChatFunctionTool JValue and prepend it to `tools`.
emittool(tools: list of ref JValue, name, desc, params: string): (list of ref JValue, string)
{
	while(len desc > 0 && (desc[len desc - 1] == '\n' || desc[len desc - 1] == ' ' || desc[len desc - 1] == '\t'))
		desc = desc[:len desc - 1];
	schema: ref JValue;
	if(params == "") {
		schema = json->jvobject(
			("type", json->jvstring("object")) ::
			("properties", json->jvobject(nil)) :: nil);
	} else {
		rbio := bufio->sopen(params);
		(jv, jerr) := json->readjson(rbio);
		if(jerr != nil)
			return (tools, sprint("tool %s: bad json: %s", name, jerr));
		schema = jv;
	}
	fnobj: list of (string, ref JValue);
	fnobj = ("parameters", schema) :: fnobj;
	if(desc != "")
		fnobj = ("description", json->jvstring(desc)) :: fnobj;
	fnobj = ("name", json->jvstring(name)) :: fnobj;
	tobj := json->jvobject(
		("function", json->jvobject(fnobj)) ::
		("type", json->jvstring("function")) :: nil);
	return (tobj :: tools, nil);
}

# Parse the markdown tools file into an array of ChatFunctionTool JValues.
# Format:
#   # toolname
#   description text...
#   ```json
#   {schema}
#   ```
parsetools(md: string): (array of ref JValue, string)
{
	if(md == nil)
		return (nil, nil);
	(nlines, lines) := sys->tokenize(md, "\n");
	if(nlines == 0)
		return (nil, nil);
	tools: list of ref JValue;
	name := "";
	desc := "";
	params := "";
	infence := 0;
	lineno := 0;
	werr: string;
	while(lines != nil) {
		ln := hd lines;
		lines = tl lines;
		lineno++;
		if(infence) {
			if(len ln >= 3 && ln[:3] == "```") {
				infence = 0;
				continue;
			}
			params += ln + "\n";
			continue;
		}
		if(len ln >= 2 && ln[:2] == "# ") {
			# emit previous tool
			if(name != "") {
				(tools, werr) = emittool(tools, name, desc, params);
				if(werr != nil)
					return (nil, sprint("line %d: %s", lineno, werr));
			}
			name = ln[2:];
			while(len name > 0 && (name[len name - 1] == ' ' || name[len name - 1] == '\t'))
				name = name[:len name - 1];
			desc = "";
			params = "";
			continue;
		}
		if(len ln >= 7 && ln[:7] == "```json") {
			infence = 1;
			continue;
		}
		if(len ln >= 3 && ln[:3] == "```") {
			infence = 1;
			continue;
		}
		if(name != "") {
			if(desc != "") desc += "\n";
			desc += ln;
		}
	}
	if(name != "") {
		(tools, werr) = emittool(tools, name, desc, params);
		if(werr != nil)
			return (nil, sprint("line %d: %s", lineno, werr));
	}
	# reverse to original order
	rev: list of ref JValue;
	for(; tools != nil; tools = tl tools)
		rev = hd tools :: rev;
	arr := array[len rev] of ref JValue;
	i := 0;
	for(; rev != nil; rev = tl rev)
		arr[i++] = hd rev;
	return (arr, nil);
}

# Query /api/v1/models at startup and format the entry for `model`.
fetchmodelinfo(model: string): string
{
	fallback := sprint("model: %s\n", model);

	(url, uerr) := Url.unpack("https://openrouter.ai/api/v1/models");
	if(uerr != nil) {
		sys->fprint(sys->fildes(2), "llmfs: models url: %s\n", uerr);
		return fallback;
	}

	hdrs: list of (string, string);
	if(apikey != nil)
		hdrs = ("Authorization", "Bearer " + apikey) :: hdrs;
	hdrs = ("Accept", "application/json") :: hdrs;

	(nil, nil, rfd, gerr) := http->get(url, Hdrs.new(hdrs));
	if(gerr != nil) {
		sys->fprint(sys->fildes(2), "llmfs: models get: %s\n", gerr);
		return fallback;
	}

	rbuf := array[65536] of byte;
	result := "";
	while((n := sys->read(rfd, rbuf, len rbuf)) > 0)
		result += string rbuf[:n];

	rbio := bufio->sopen(result);
	(jv, jerr) := json->readjson(rbio);
	if(jerr != nil) {
		sys->fprint(sys->fildes(2), "llmfs: models json: %s\n", jerr);
		return fallback;
	}

	data := jv.get("data");
	if(data == nil)
		return fallback;
	pick da := data {
	Array =>
		for(i := 0; i < len da.a; i++) {
			mid := da.a[i].get("id");
			if(mid == nil)
				continue;
			pick ms := mid {
			String =>
				if(ms.s == model)
					return formatmodel(da.a[i]);
			}
		}
	}
	return fallback;
}

formatmodel(m: ref JValue): string
{
	s := "model: " + jvtext(m, "id") + "\n";
	v := jvtext(m, "name");
	if(v != "")
		s += "name: " + v + "\n";
	v = jvtext(m, "context_length");
	if(v != "")
		s += "context_length: " + v + "\n";

	tp := m.get("top_provider");
	if(tp != nil) {
		v = jvtext(tp, "max_completion_tokens");
		if(v != "")
			s += "max_completion_tokens: " + v + "\n";
		v = jvtext(tp, "is_moderated");
		if(v != "")
			s += "is_moderated: " + v + "\n";
	}

	p := m.get("pricing");
	if(p != nil) {
		v = jvtext(p, "prompt");
		if(v != "")
			s += "pricing_prompt: " + v + "\n";
		v = jvtext(p, "completion");
		if(v != "")
			s += "pricing_completion: " + v + "\n";
	}

	arch := m.get("architecture");
	if(arch != nil) {
		v = jvtext(arch, "modality");
		if(v != "")
			s += "modality: " + v + "\n";
		v = jvtext(arch, "tokenizer");
		if(v != "")
			s += "tokenizer: " + v + "\n";
	}
	return s;
}

jvtext(obj: ref JValue, key: string): string
{
	if(obj == nil)
		return "";
	v := obj.get(key);
	if(v == nil)
		return "";
	pick x := v {
	String =>	return x.s;
	Int =>		return string x.value;
	Real =>		return string x.value;
	True =>		return "true";
	False =>	return "false";
	Null =>		return "";
	}
	return "";
}

# Build the messages array JValue from a snapshot.
buildmessages(snap: ref Snap): array of ref JValue
{
	msgs: list of ref JValue;
	if(snap.system_prompt != "") {
		msgs = json->jvobject(
			("role", json->jvstring("system")) ::
			("content", json->jvstring(snap.system_prompt)) :: nil) :: msgs;
	}
	for(j := 0; j < len snap.messages; j++) {
		mm := snap.messages[j];
		if(mm == nil)
			continue;
		if(mm.role == "")
			continue;
		fields: list of (string, ref JValue);
		fields = ("role", json->jvstring(mm.role)) :: fields;
		if(mm.content != "" || mm.role != "assistant")
			fields = ("content", json->jvstring(mm.content)) :: fields;
		if(mm.mname != "")
			fields = ("name", json->jvstring(mm.mname)) :: fields;
		if(mm.role == "tool" && mm.tool_call_id != "")
			fields = ("tool_call_id", json->jvstring(mm.tool_call_id)) :: fields;
		if(mm.role == "assistant" && mm.tool_calls != "") {
			# Re-parse the stored JSON text into a JValue
			rb := bufio->sopen(mm.tool_calls);
			(jv, jerr) := json->readjson(rb);
			if(jerr == nil && jv != nil)
				fields = ("tool_calls", jv) :: fields;
		}
		msgs = json->jvobject(fields) :: msgs;
	}
	# Reverse list to original order.
	rmsgs: list of ref JValue;
	for(ml := msgs; ml != nil; ml = tl ml)
		rmsgs = hd ml :: rmsgs;
	arr := array[len rmsgs] of ref JValue;
	i := 0;
	for(; rmsgs != nil; rmsgs = tl rmsgs)
		arr[i++] = hd rmsgs;
	return arr;
}

# API call goroutine
apicall(snap: ref Snap)
{
	connx := snap.connx;

	model := snap.model;
	if(model == "")
		model = default_model;

	params: list of (string, ref JValue);
	params = ("model", json->jvstring(model)) :: params;

	# messages
	if(snap.mode == Mdata) {
		if(snap.data_prompt == "") {
			apich <-= ref ApiResult(connx, snap.mode, "", "", "", "no prompt");
			return;
		}
		marr := array[1] of ref JValue;
		marr[0] = json->jvobject(
			("role", json->jvstring("user")) ::
			("content", json->jvstring(snap.data_prompt)) :: nil);
		params = ("messages", json->jvarray(marr)) :: params;
	} else {
		marr := buildmessages(snap);
		if(len marr == 0) {
			apich <-= ref ApiResult(connx, snap.mode, "", "", "", "no messages");
			return;
		}
		params = ("messages", json->jvarray(marr)) :: params;
		# tools
		if(snap.tools_md != "") {
			(tarr, terr) := parsetools(snap.tools_md);
			if(terr != nil) {
				apich <-= ref ApiResult(connx, snap.mode, "", "", "", "tools: " + terr);
				return;
			}
			if(len tarr > 0)
				params = ("tools", json->jvarray(tarr)) :: params;
		}
		if(snap.tool_choice != "")
			params = ("tool_choice", json->jvstring(snap.tool_choice)) :: params;
		if(snap.transform != 0) {
			tx := array[1] of ref JValue;
			tx[0] = json->jvstring("middle-out");
			params = ("transforms", json->jvarray(tx)) :: params;
		}
	}

	if(snap.temp >= 0.0)
		params = ("temperature", json->jvreal(snap.temp)) :: params;
	if(snap.top_p >= 0.0)
		params = ("top_p", json->jvreal(snap.top_p)) :: params;
	if(snap.max_tokens > 0)
		params = ("max_tokens", json->jvint(snap.max_tokens)) :: params;
	if(snap.seed >= 0)
		params = ("seed", json->jvint(snap.seed)) :: params;

	reqjson := json->jvobject(params);
	body := array of byte reqjson.text();

	# HTTP POST
	(url, uerr) := Url.unpack("https://openrouter.ai/api/v1/chat/completions");
	if(uerr != nil) {
		apich <-= ref ApiResult(connx, snap.mode, "", "", "", "bad url: " + uerr);
		return;
	}

	hdrs: list of (string, string);
	hdrs = ("Authorization", "Bearer " + apikey) :: hdrs;
	hdrs = ("Content-Type", "application/json") :: hdrs;

	req := Req.mk(Http->POST, url, Http->HTTP_11, Hdrs.new(hdrs));
	req.body = body;

	(fd, derr) := req.dial();
	if(derr != nil) {
		apich <-= ref ApiResult(connx, snap.mode, "", "", "", "dial: " + derr);
		return;
	}

	werr := req.write(fd);
	if(werr != nil) {
		apich <-= ref ApiResult(connx, snap.mode, "", "", "", "write: " + werr);
		return;
	}

	bio := bufio->fopen(fd, Bufio->OREAD);
	if(bio == nil) {
		apich <-= ref ApiResult(connx, snap.mode, "", "", "", sprint("bufio fopen: %r"));
		return;
	}

	(resp, rerr) := Resp.read(bio);
	if(rerr != nil) {
		apich <-= ref ApiResult(connx, snap.mode, "", "", "", "read resp: " + rerr);
		return;
	}

	if(resp.st[0] != '2') {
		apich <-= ref ApiResult(connx, snap.mode, "", "", "", sprint("http %s: %s", resp.st, resp.stmsg));
		return;
	}

	if(!resp.hasbody(Http->POST)) {
		apich <-= ref ApiResult(connx, snap.mode, "", "", "", "no response body");
		return;
	}

	(rfd, berr) := resp.body(bio);
	if(berr != nil) {
		apich <-= ref ApiResult(connx, snap.mode, "", "", "", "body: " + berr);
		return;
	}

	rbuf := array[65536] of byte;
	result := "";
	while((n := sys->read(rfd, rbuf, len rbuf)) > 0)
		result += string rbuf[:n];

	# Parse JSON response
	rbio := bufio->sopen(result);
	(jv, jerr) := json->readjson(rbio);
	if(jerr != nil) {
		apich <-= ref ApiResult(connx, snap.mode, "", "", "", "json parse: " + jerr);
		return;
	}

	choices := jv.get("choices");
	if(choices == nil || !choices.isarray()) {
		apich <-= ref ApiResult(connx, snap.mode, "", "", "", "no choices in response: " + result);
		return;
	}
	pick ca := choices {
	Array =>
		if(len ca.a == 0) {
			apich <-= ref ApiResult(connx, snap.mode, "", "", "", "empty choices");
			return;
		}
		choice := ca.a[0];
		fr := jvtext(choice, "finish_reason");
		msg := choice.get("message");
		if(msg == nil) {
			apich <-= ref ApiResult(connx, snap.mode, "", "", fr, "no message in choice");
			return;
		}
		content := "";
		cv := msg.get("content");
		if(cv != nil) {
			pick cs := cv {
			String =>	content = cs.s;
			Null =>		content = "";
			}
		}
		toolcalls := "";
		tcv := msg.get("tool_calls");
		if(tcv != nil)
			toolcalls = tcv.text();
		apich <-= ref ApiResult(connx, snap.mode, content, toolcalls, fr, nil);
		return;
	}
	apich <-= ref ApiResult(connx, snap.mode, "", "", "", "unexpected response format");
}
