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

# File types encoded in low 4 bits of QID path
Qroot, Qclone, Qinfo, Qdir, Qctl, Qdata, Qstatus, Qchat, Qsystem, Quser, Qassistant: con iota;

connfiles := array[] of {
	(Qctl, "ctl"),
	(Qdata, "data"),
	(Qstatus, "status"),
	(Qchat, "chat"),
};

chatfiles := array[] of {
	(Qsystem, "system"),
	(Quser, "user"),
	(Qassistant, "assistant"),
};

# Connection states
Idle, Prompting, Generating, Done: con iota;
statenames := array[] of { "Idle", "Prompting", "Generating", "Done" };

LlmConn: adt {
	id:		int;
	x:		int;		# slot index in conns array
	path:		big;		# base path (without file type bits)
	state:		int;
	model:		string;
	system_prompt:	string;
	user_prompt:	string;
	data_prompt:	string;
	output:		string;
	outerr:		string;
	temp:		real;
	top_p:		real;
	max_tokens:	int;
	seed:		int;
};

ApiResult: adt {
	connx:	int;
	result:	string;
	err:	string;
};

PendingRead: adt {
	tag:	int;
	offset:	big;
	count:	int;
	connx:	int;
};

conns:		array of ref LlmConn;
next_conn_id :=	1;
pathgen :=	0;
default_model :=	"openai/gpt-4.1-nano";
apikey:		string;
apich:		chan of ref ApiResult;
user:		string;

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
	return int path & 16rF;
}

INDEX(path: big): int
{
	return (int path >> 4) & 16rFFFF;
}

findconn(path: big): ref LlmConn
{
	i := INDEX(path);
	if(i >= len conns || (c := conns[i]) == nil || c.path != (path & ~big 16rF))
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
	path := big((pathgen++ << 20) | (i << 4));
	c := ref LlmConn(
		id, i, path, Idle,
		default_model,
		"", "", "",	# system_prompt, user_prompt, data_prompt
		"", nil,	# output, outerr
		1.0, 0.9,	# temp, top_p
		-1, -1		# max_tokens, seed
	);
	conns[i] = c;
	return c;
}

freeconn(c: ref LlmConn)
{
	if(c != nil && c.x < len conns)
		conns[c.x] = nil;
}

# Dir entry generation
dirgen(p: big, name: string, c: ref LlmConn): (ref Sys->Dir, string)
{
	case TYPE(p) {
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
		if(name == nil)
			name = string c.id;
		return (mkdir(Sys->Qid(p, 0, Sys->QTDIR), name, big 0, 8r755), nil);
	Qctl =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "ctl", big 0, 8r666), nil);
	Qdata =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "data", big 0, 8r666), nil);
	Qstatus =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "status", big 0, 8r444), nil);
	Qchat =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTDIR), "chat", big 0, 8r755), nil);
	Qsystem =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "system", big 0, 8r666), nil);
	Quser =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "user", big 0, 8r666), nil);
	Qassistant =>
		return (mkdir(Sys->Qid(p, 0, Sys->QTFILE), "assistant", big 0, 8r444), nil);
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
			case TYPE(n.path) {
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
				# Try as connection number
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
				base := n.path & ~big 16rF;
				for(j := 0; j < len connfiles; j++) {
					(ftype, fname) := connfiles[j];
					if(n.name == fname) {
						n.reply <-= dirgen(base | big ftype, fname, nil);
						break Pick;
					}
				}
				n.reply <-= (nil, Enotfound);
			Qchat =>
				if(n.name == "..") {
					base := n.path & ~big 16rF;
					n.reply <-= dirgen(base | big Qdir, nil, nil);
					break;
				}
				base := n.path & ~big 16rF;
				for(j := 0; j < len chatfiles; j++) {
					(ftype, fname) := chatfiles[j];
					if(n.name == fname) {
						n.reply <-= dirgen(base | big ftype, fname, nil);
						break Pick;
					}
				}
				n.reply <-= (nil, Enotfound);
			Qctl or Qdata or Qstatus =>
				if(n.name == "..") {
					base := n.path & ~big 16rF;
					n.reply <-= dirgen(base | big Qdir, nil, nil);
					break;
				}
				n.reply <-= (nil, Enotfound);
			Qsystem or Quser or Qassistant =>
				if(n.name == "..") {
					base := n.path & ~big 16rF;
					n.reply <-= dirgen(base | big Qchat, nil, nil);
					break;
				}
				n.reply <-= (nil, Enotfound);
			* =>
				n.reply <-= (nil, Enotfound);
			}
		Readdir =>
			case TYPE(n.path) {
			Qroot =>
				# entries: clone, info, then connection directories
				slot := 0;
				count := n.count;
				off := n.offset;
				if(off == 0 && count > 0) {
					n.reply <-= dirgen(big Qclone, nil, nil);
					count--;
					slot++;
				} else if(off <= 0)
					slot++;
				if(slot >= off && off <= 1 && count > 0) {
					n.reply <-= dirgen(big Qinfo, nil, nil);
					count--;
					slot++;
				} else if(off <= 1)
					slot++;
				# connection dirs start at offset 2
				ci := 0;
				for(j := 0; j < len conns && count > 0; j++) {
					c := conns[j];
					if(c == nil)
						continue;
					if(slot + ci >= off) {
						n.reply <-= dirgen(c.path | big Qdir, string c.id, c);
						count--;
					}
					ci++;
				}
				n.reply <-= (nil, nil);
			Qdir =>
				base := n.path & ~big 16rF;
				for(j := n.offset; --n.count >= 0 && j < len connfiles; j++) {
					(ftype, fname) := connfiles[j];
					n.reply <-= dirgen(base | big ftype, fname, nil);
				}
				n.reply <-= (nil, nil);
			Qchat =>
				base := n.path & ~big 16rF;
				for(j := n.offset; --n.count >= 0 && j < len chatfiles; j++) {
					(ftype, fname) := chatfiles[j];
					n.reply <-= dirgen(base | big ftype, fname, nil);
				}
				n.reply <-= (nil, nil);
			* =>
				n.reply <-= (nil, nil);
			}
		}
	}
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
			case TYPE(c.path) {
			Qclone =>
				srv.reply(styxservers->readbytes(m, c.data));
			Qinfo =>
				info := sprint("model: %s\n", default_model);
				srv.reply(styxservers->readstr(m, info));
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
			Qdata or Qassistant =>
				conn := findconn(c.path);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(conn.state == Generating) {
					pending = ref PendingRead(m.tag, m.offset, m.count, conn.x) :: pending;
					break;
				}
				if(conn.state == Done) {
					if(conn.outerr != nil) {
						srv.reply(ref Rmsg.Error(m.tag, conn.outerr));
						break;
					}
					srv.reply(styxservers->readstr(m, conn.output));
				} else
					srv.reply(styxservers->readstr(m, ""));
			Qsystem =>
				conn := findconn(c.path);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readstr(m, conn.system_prompt));
			Quser =>
				conn := findconn(c.path);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readstr(m, conn.user_prompt));
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
			if(conn == nil && TYPE(c.path) != Qclone && TYPE(c.path) != Qinfo) {
				srv.reply(ref Rmsg.Error(m.tag, Enotfound));
				break;
			}
			case TYPE(c.path) {
			Qctl =>
				cerr := parsectl(conn, string m.data);
				if(cerr != nil) {
					srv.reply(ref Rmsg.Error(m.tag, cerr));
					break;
				}
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qdata =>
				conn.data_prompt += string m.data;
				conn.state = Prompting;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qsystem =>
				if(m.offset == big 0 && conn.system_prompt != "")
					conn.system_prompt = "";
				conn.system_prompt += string m.data;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Quser =>
				if(m.offset == big 0 && conn.user_prompt != "")
					conn.user_prompt = "";
				conn.user_prompt += string m.data;
				conn.state = Prompting;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}
		Clunk =>
			c := srv.clunk(m);
			if(c == nil)
				break;
			if(c.isopen && (c.mode & 3) != Styx->OREAD) {
				conn := findconn(c.path);
				if(conn != nil && conn.state == Prompting) {
					case TYPE(c.path) {
					Quser or Qdata =>
						conn.state = Generating;
						conn.output = "";
						conn.outerr = nil;
						spawn apicall(conn.x);
					}
				}
			}
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
		if(ar.err != nil) {
			c.outerr = ar.err;
			c.output = "";
		} else {
			c.output = ar.result;
			c.outerr = nil;
		}
		c.state = Done;
		# satisfy pending reads
		newp: list of ref PendingRead;
		for(pl := pending; pl != nil; pl = tl pl) {
			pr := hd pl;
			if(pr.connx == ar.connx)
				replyread(srv, pr, c);
			else
				newp = pr :: newp;
		}
		pending = newp;
	}
}

replyread(srv: ref Styxserver, pr: ref PendingRead, conn: ref LlmConn)
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

parsectl(conn: ref LlmConn, cmd: string): string
{
	(n, toks) := sys->tokenize(cmd, " \t\n");
	if(n < 1)
		return Ebadarg;
	verb := hd toks;
	case verb {
	"temp" =>
		if(n < 2) return Ebadarg;
		conn.temp = real hd tl toks;
	"top" =>
		if(n < 2) return Ebadarg;
		conn.top_p = real hd tl toks;
	"max_tokens" =>
		if(n < 2) return Ebadarg;
		conn.max_tokens = int hd tl toks;
	"seed" =>
		if(n < 2) return Ebadarg;
		conn.seed = int hd tl toks;
	"mode" =>
		;	# accept but ignore for API mode
	"model" =>
		if(n < 2) return Ebadarg;
		conn.model = hd tl toks;
	"reset" =>
		conn.state = Idle;
		conn.system_prompt = "";
		conn.user_prompt = "";
		conn.data_prompt = "";
		conn.output = "";
		conn.outerr = nil;
	* =>
		return "unknown ctl command";
	}
	return nil;
}

# API call goroutine
apicall(connx: int)
{
	c := conns[connx];
	if(c == nil) {
		apich <-= ref ApiResult(connx, "", "connection gone");
		return;
	}

	# Build messages array
	msgs: list of ref JValue;
	if(c.user_prompt != "") {
		# Chat mode
		if(c.system_prompt != "")
			msgs = json->jvobject(
				("role", json->jvstring("system")) ::
				("content", json->jvstring(c.system_prompt)) :: nil
			) :: msgs;
		msgs = json->jvobject(
			("role", json->jvstring("user")) ::
			("content", json->jvstring(c.user_prompt)) :: nil
		) :: msgs;
	} else if(c.data_prompt != "") {
		# Data mode
		msgs = json->jvobject(
			("role", json->jvstring("user")) ::
			("content", json->jvstring(c.data_prompt)) :: nil
		) :: msgs;
	} else {
		apich <-= ref ApiResult(connx, "", "no prompt");
		return;
	}

	# Reverse and convert to array
	rmsgs: list of ref JValue;
	for(ml := msgs; ml != nil; ml = tl ml)
		rmsgs = hd ml :: rmsgs;
	msgarr := array[len rmsgs] of ref JValue;
	i := 0;
	for(; rmsgs != nil; rmsgs = tl rmsgs)
		msgarr[i++] = hd rmsgs;

	# Build request JSON
	model := c.model;
	if(model == "")
		model = default_model;

	params: list of (string, ref JValue);
	params = ("model", json->jvstring(model)) :: params;
	params = ("messages", json->jvarray(msgarr)) :: params;
	if(c.temp >= 0.0)
		params = ("temperature", json->jvreal(c.temp)) :: params;
	if(c.top_p >= 0.0)
		params = ("top_p", json->jvreal(c.top_p)) :: params;
	if(c.max_tokens > 0)
		params = ("max_tokens", json->jvint(c.max_tokens)) :: params;
	if(c.seed >= 0)
		params = ("seed", json->jvint(c.seed)) :: params;

	reqjson := json->jvobject(params);
	body := array of byte reqjson.text();

	# HTTP POST
	(url, uerr) := Url.unpack("https://openrouter.ai/api/v1/chat/completions");
	if(uerr != nil) {
		apich <-= ref ApiResult(connx, "", "bad url: " + uerr);
		return;
	}

	hdrs: list of (string, string);
	hdrs = ("Authorization", "Bearer " + apikey) :: hdrs;
	hdrs = ("Content-Type", "application/json") :: hdrs;

	req := Req.mk(Http->POST, url, Http->HTTP_11, Hdrs.new(hdrs));
	req.body = body;

	(fd, derr) := req.dial();
	if(derr != nil) {
		apich <-= ref ApiResult(connx, "", "dial: " + derr);
		return;
	}

	werr := req.write(fd);
	if(werr != nil) {
		apich <-= ref ApiResult(connx, "", "write: " + werr);
		return;
	}

	bio := bufio->fopen(fd, Bufio->OREAD);
	if(bio == nil) {
		apich <-= ref ApiResult(connx, "", sprint("bufio fopen: %r"));
		return;
	}

	(resp, rerr) := Resp.read(bio);
	if(rerr != nil) {
		apich <-= ref ApiResult(connx, "", "read resp: " + rerr);
		return;
	}

	if(resp.st[0] != '2') {
		apich <-= ref ApiResult(connx, "", sprint("http %s: %s", resp.st, resp.stmsg));
		return;
	}

	if(!resp.hasbody(Http->POST)) {
		apich <-= ref ApiResult(connx, "", "no response body");
		return;
	}

	(rfd, berr) := resp.body(bio);
	if(berr != nil) {
		apich <-= ref ApiResult(connx, "", "body: " + berr);
		return;
	}

	# Read full body
	rbuf := array[65536] of byte;
	result := "";
	while((n := sys->read(rfd, rbuf, len rbuf)) > 0)
		result += string rbuf[:n];

	# Parse JSON response
	rbio := bufio->sopen(result);
	(jv, jerr) := json->readjson(rbio);
	if(jerr != nil) {
		apich <-= ref ApiResult(connx, "", "json parse: " + jerr);
		return;
	}

	# Extract choices[0].message.content
	choices := jv.get("choices");
	if(choices == nil || !choices.isarray()) {
		apich <-= ref ApiResult(connx, "", "no choices in response: " + result);
		return;
	}
	pick ca := choices {
	Array =>
		if(len ca.a == 0) {
			apich <-= ref ApiResult(connx, "", "empty choices");
			return;
		}
		msg := ca.a[0].get("message");
		if(msg == nil) {
			apich <-= ref ApiResult(connx, "", "no message in choice");
			return;
		}
		content := msg.get("content");
		if(content == nil || !content.isstring()) {
			apich <-= ref ApiResult(connx, "", "no content in message");
			return;
		}
		pick cs := content {
		String =>
			apich <-= ref ApiResult(connx, cs.s, nil);
			return;
		}
	}
	apich <-= ref ApiResult(connx, "", "unexpected response format");
}
