export type JsonObject = Record<string, unknown>;

/**
 * The request body as a JSON object, or a 400 response if it is malformed JSON, empty, `null`, an array or a
 * primitive. Every JSON route reads its body through this; callers still validate each field they use.
 */
export async function readJsonObject(request: Request): Promise<JsonObject | Response> {
  let value: unknown;
  try {
    value = await request.json();
  } catch {
    return badBody();
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) return badBody();
  return value as JsonObject;
}

function badBody() {
  return new Response("The body must be a JSON object", { status: 400 });
}
