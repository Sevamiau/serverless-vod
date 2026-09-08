function handler(event) {
  var request = event.request;
  var headers = request.headers;

  if (!headers.referer || !headers.host) {
    return { statusCode: 403, statusDescription: "Forbidden" };
  }

  var refererValue = headers.referer.value;
  var hostValue = headers.host.value;

  var withoutScheme = refererValue.replace(/^https?:\/\//, "");
  var refererHost = withoutScheme.split("/")[0];

  if (refererHost !== hostValue) {
    return { statusCode: 403, statusDescription: "Forbidden" };
  }

  return request;
}
