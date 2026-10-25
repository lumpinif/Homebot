export interface Env {
  DB: D1Database;
  RELEASES: R2Bucket;
  EMAIL: SendEmail;
  PING_LIMIT: RateLimit;
  SUBSCRIBE_LIMIT: RateLimit;
  HMAC_SECRET: string;
  SITE_ORIGIN: string;
  MAIL_FROM: string;
  MAIL_DAILY_CAP: string;
}

/** One outgoing email. Kept small so tests can swap in a fake that sends nothing. */
export interface Mail {
  to: string;
  subject: string;
  text: string;
  html: string;
  headers?: Record<string, string>;
}

export interface Deps {
  now: () => Date;
  send: (mail: Mail) => Promise<void>;
}

export function liveDeps(env: Env): Deps {
  return {
    now: () => new Date(),
    send: async (m) => {
      await env.EMAIL.send({ from: { email: env.MAIL_FROM, name: "Homebot" }, to: m.to, subject: m.subject, text: m.text, html: m.html, headers: m.headers });
    },
  };
}
