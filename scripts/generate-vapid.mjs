import webpush from "web-push";

const keys = webpush.generateVAPIDKeys();
console.log("\nVITE_VAPID_PUBLIC_KEY=" + keys.publicKey);
console.log("VAPID_PUBLIC_KEY=" + keys.publicKey);
console.log("VAPID_PRIVATE_KEY=" + keys.privateKey);
console.log("\nGuarde a chave privada apenas nos secrets da Edge Function.\n");
