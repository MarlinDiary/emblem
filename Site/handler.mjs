export default {
  async fetch(request) {
    const url = new URL(request.url);
    const headers = {
      'Content-Security-Policy': "default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
      'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
      'Cache-Control': 'public, max-age=300',
      'Strict-Transport-Security': 'max-age=31536000',
    };
    if (url.hostname === 'mailportrait.protoyard.com') {
      return new Response(null,{status:308,headers:{...headers,Location:`https://emblem.protoyard.com${url.pathname}${url.search}`}});
    }
    if (!['GET','HEAD'].includes(request.method)) {
      return new Response('Method not allowed', {status:405,headers:{...headers,Allow:'GET, HEAD'}});
    }
    if (['/privacy','/terms'].includes(url.pathname)) {
      return new Response(null,{status:308,headers:{...headers,Location:url.pathname+'/'}});
    }
    const asset = Object.hasOwn(files,url.pathname) ? files[url.pathname] : undefined;
    if (!asset) return new Response(request.method==='HEAD'?null:'Page not found',{status:404,headers:{...headers,'Content-Type':'text/plain; charset=utf-8'}});
    return new Response(request.method==='HEAD'?null:asset[1],{headers:{...headers,'Content-Type':asset[0]}});
  },
};
