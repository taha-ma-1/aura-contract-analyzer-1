// ============================================
// middleware.ts — Enterprise Security Gate
//
// Applied to every request before routing:
//  1. JWT verification (Supabase session)
//  2. Subscription check on /api/analyze
//  3. Security headers on all responses
//  4. Auth redirects (dashboard ↔ login)
// ============================================
import { NextResponse, type NextRequest } from 'next/server';
import { createServerClient, type CookieOptions } from '@supabase/ssr';

const SECURITY_HEADERS: Record<string, string> = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'X-XSS-Protection': '1; mode=block',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
  'Strict-Transport-Security': 'max-age=63072000; includeSubDomains; preload',
  'Content-Security-Policy': [
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline' https://js.stripe.com",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' https://fonts.gstatic.com",
    "img-src 'self' data: https:",
    "connect-src 'self' https://*.supabase.co https://api.stripe.com",
    "frame-src https://js.stripe.com",
  ].join('; '),
};

function applySecurityHeaders(res: NextResponse) {
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) {
    res.headers.set(k, v);
  }
  return res;
}

export async function middleware(request: NextRequest) {
  const path = request.nextUrl.pathname;

  let response = applySecurityHeaders(
    NextResponse.next({ request: { headers: request.headers } })
  );

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        get(name: string) { return request.cookies.get(name)?.value; },
        set(name: string, value: string, options: CookieOptions) {
          request.cookies.set({ name, value, ...options });
          response = applySecurityHeaders(NextResponse.next({ request: { headers: request.headers } }));
          response.cookies.set({ name, value, ...options });
        },
        remove(name: string, options: CookieOptions) {
          request.cookies.set({ name, value: '', ...options });
          response = applySecurityHeaders(NextResponse.next({ request: { headers: request.headers } }));
          response.cookies.set({ name, value: '', ...options });
        },
      },
    }
  );

  const { data: { user } } = await supabase.auth.getUser();

  // ── Dashboard: auth required ───────────────
  if (path.startsWith('/dashboard') && !user) {
    const url = new URL('/login', request.url);
    url.searchParams.set('redirect', path);
    return NextResponse.redirect(url);
  }

  // ── Login/signup: redirect if already authed ─
  if (['/login', '/signup'].includes(path) && user) {
    return NextResponse.redirect(new URL('/dashboard', request.url));
  }

  // ── API routes: session required ───────────
  if (path.startsWith('/api/analyze') || path.startsWith('/api/stripe')) {
    if (!user) {
      return applySecurityHeaders(
        NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
      );
    }

    // Defense-in-depth: pre-check subscription on analyze
    // (full check also inside the route handler)
    if (path === '/api/analyze') {
      const { data: profile } = await supabase
        .from('profiles')
        .select('subscription_status, free_analyses_used')
        .eq('id', user.id)
        .single();

      const isPro = ['active', 'trialing'].includes(profile?.subscription_status ?? '');
      const freeUsed = profile?.free_analyses_used ?? 0;

      // Gate expensive AI calls at middleware level
      if (!isPro && freeUsed >= 1) {
        return applySecurityHeaders(
          NextResponse.json(
            { error: 'FREE_LIMIT_REACHED', message: 'Upgrade to Pro for unlimited analyses.' },
            { status: 402 }
          )
        );
      }

      response.headers.set('X-User-Id', user.id);
      response.headers.set('X-Is-Pro', String(isPro));
    }
  }

  return response;
}

export const config = {
  matcher: [
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
};
