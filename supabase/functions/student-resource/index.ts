const origin = "https://school45green.github.io";
const headers = {
  "access-control-allow-origin": origin,
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-allow-headers": "content-type",
  "cache-control": "no-store",
  "content-type": "application/json",
};
const json = (value, status = 200) => new Response(JSON.stringify(value), {status, headers});
Deno.serve(async (request) => {
  if (request.headers.get("origin") !== origin) return json(null, 403);
  if (request.method === "OPTIONS") return new Response(null, {status: 204, headers});
  if (request.method !== "POST") return json(null, 405);
  try {
    const body = await request.text();
    if (body.length > 400) return json(null, 400);
    const data = JSON.parse(body);
    const {token, group, id} = data || {};
    if (typeof token !== "string" || !/^[0-9a-f]{64}$/.test(token) ||
      !["units", "honors"].includes(group) || typeof id !== "string" ||
      !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id)) return json(null, 400);
    const url = Deno.env.get("SUPABASE_URL");
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) return json(null, 503);
    const auth = {"content-type": "application/json", apikey: key, authorization: "Bearer "+key};
    const check = await fetch(url+"/rest/v1/rpc/hub_resolve_student_resource", {
      method: "POST", headers: auth, body: JSON.stringify({p_token: token, p_group: group, p_id: id}),
    });
    if (!check.ok) return json(null, 503);
    const path = await check.json();
    if (path !== group+"/"+id.toLowerCase()+"/resource") return json(null, 404);
    const sign = await fetch(url+"/storage/v1/object/sign/hub-private/"+path, {
      method: "POST", headers: auth, body: JSON.stringify({expiresIn: 45}),
    });
    if (!sign.ok) return json(null, 404);
    const {signedURL} = await sign.json();
    if (typeof signedURL !== "string" || !signedURL.startsWith("/object/sign/hub-private/")) return json(null, 503);
    return json({url: url+"/storage/v1"+signedURL});
  } catch {
    return json(null, 400);
  }
});
