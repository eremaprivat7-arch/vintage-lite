const encoder = new TextEncoder();
async function vaultKey(secret) {
  const bytes=await crypto.subtle.digest("SHA-256",encoder.encode(secret));
  return crypto.subtle.importKey("raw",bytes,"AES-GCM",false,["encrypt","decrypt"]);
}
export async function seal(token,secret,uid) {
  const iv=crypto.getRandomValues(new Uint8Array(12));
  const encrypted=await crypto.subtle.encrypt({name:"AES-GCM",iv,additionalData:encoder.encode(uid)},await vaultKey(secret),encoder.encode(token));
  return JSON.stringify({iv:Array.from(iv),data:Array.from(new Uint8Array(encrypted))});
}
export async function unseal(payload,secret,uid) {
  const data=JSON.parse(payload);
  const bytes=await crypto.subtle.decrypt({name:"AES-GCM",iv:new Uint8Array(data.iv),additionalData:encoder.encode(uid)},await vaultKey(secret),new Uint8Array(data.data));
  return new TextDecoder().decode(bytes);
}
