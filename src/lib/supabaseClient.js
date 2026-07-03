// ============================================================
// KORA LEARN — Cliente Supabase
// Instalacao no projeto Vite:  npm install @supabase/supabase-js
// ============================================================
import { createClient } from "@supabase/supabase-js";

// Crie um arquivo .env na raiz do projeto Vite com:
//   VITE_SUPABASE_URL=https://SEU-PROJETO.supabase.co
//   VITE_SUPABASE_ANON_KEY=chave-anon-publica
// (Settings -> API no painel do Supabase)
// A chave anon e segura no frontend: o RLS e quem protege os dados.

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
  },
});
