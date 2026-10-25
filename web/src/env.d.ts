// beUI's tooltip warns in development through process.env.NODE_ENV, which Vite replaces at build.
declare const process: { env: { NODE_ENV?: string } };
