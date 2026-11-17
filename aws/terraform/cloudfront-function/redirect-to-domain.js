var DOMAIN = "${domain}";

function queryString(q) {
  var parts = [];
  for (var key in q) {
    var values = q[key].multiValue || [q[key]];
    for (var i = 0; i < values.length; i++) {
      parts.push(values[i].value === "" ? key : key + "=" + values[i].value);
    }
  }
  return parts.length ? "?" + parts.join("&") : "";
}

function handler(event) {
  var request = event.request;
  var host = request.headers.host ? request.headers.host.value : "";

  if (!host.endsWith(".cloudfront.net")) {
    return request;
  }

  var keepsMethod = request.method !== "GET" && request.method !== "HEAD";
  return {
    statusCode: keepsMethod ? 308 : 301,
    statusDescription: keepsMethod ? "Permanent Redirect" : "Moved Permanently",
    headers: {
      location: { value: "https://" + DOMAIN + request.uri + queryString(request.querystring) },
    },
  };
}
