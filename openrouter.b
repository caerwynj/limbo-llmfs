implement Openrouter;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "mhttp.m";
	http: Http;
	Url, Hdrs, Req, Resp: import http;

Openrouter: module {
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

APIKEY: con "";

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	http = load Http Http->PATH;
	if(http == nil)
		fail(sprint("loading http: %r"));
	http->init(bufio);
	http->debug = 0;

	sys->bind("#T", "/dev", Sys->MAFTER);

	urlstr := "https://openrouter.ai/api/v1/chat/completions";
	(url, uerr) := Url.unpack(urlstr);
	if(uerr != nil)
		fail("parsing url: "+uerr);

	body := array of byte (
		"{\"model\":\"openai/gpt-4.1-nano\","
		+ "\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one sentence.\"}]}"
	);

	hdrs: list of (string, string);
	hdrs = ("Authorization", "Bearer "+APIKEY) :: hdrs;
	hdrs = ("Content-Type", "application/json") :: hdrs;

	req := Req.mk(Http->POST, url, Http->HTTP_11, Hdrs.new(hdrs));
	req.body = body;

	(fd, derr) := req.dial();
	if(derr != nil)
		fail("dial: "+derr);

	werr := req.write(fd);
	if(werr != nil)
		fail("write: "+werr);

	b := bufio->fopen(fd, Bufio->OREAD);
	if(b == nil)
		fail(sprint("bufio fopen: %r"));

	(resp, rerr) := Resp.read(b);
	if(rerr != nil)
		fail("reading response: "+rerr);

	sys->print("status: %s %s\n", resp.st, resp.stmsg);

	if(!resp.hasbody(Http->POST)) {
		sys->print("(no body)\n");
		return;
	}

	(rfd, berr) := resp.body(b);
	if(berr != nil)
		fail("reading body: "+berr);

	buf := array[65536] of byte;
	total := 0;
	result := "";
	while((n := sys->read(rfd, buf, len buf)) > 0) {
		result += string buf[:n];
		total += n;
	}

	sys->print("%s\n", result);
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "openrouter: %s\n", s);
	raise "fail:"+s;
}
