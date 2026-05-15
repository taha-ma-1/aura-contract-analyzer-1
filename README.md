# ContractScan AI 🛡️
### AI-powered contract risk analyzer. SaaS. $9.99/month.

---

## 🚀 Setup in 15 Minutes

### 1. Install dependencies
```bash
npm install
```

### 2. Configure environment
```bash
cp .env.example .env.local
# Fill in the values (see below)
```

### 3. Set up Supabase
1. Go to [supabase.com](https://supabase.com) → New Project
2. Copy your `Project URL` and `anon key` → `.env.local`
3. Copy your `service_role key` → `.env.local`
4. Go to SQL Editor → Run the schema from `lib/supabase.ts` (bottom of file)

### 4. Set up OpenAI
1. Go to [platform.openai.com](https://platform.openai.com/api-keys)
2. Create API key → `.env.local`

### 5. Set up Stripe
1. Go to [dashboard.stripe.com](https://dashboard.stripe.com)
2. Get publishable + secret keys → `.env.local`
3. Create a Product → Recurring Price → $9.99/month → copy Price ID → `.env.local`
4. Set up webhook:
   ```bash
   # Install Stripe CLI
   stripe listen --forward-to localhost:3000/api/stripe/webhook
   # Copy webhook secret → .env.local
   ```

### 6. Run locally
```bash
npm run dev
# Open http://localhost:3000
```

---

## 🏗️ Architecture

```
Landing Page (/) → Signup (/signup) → Dashboard (/dashboard)
                                           ↓
                                    Upload Contract
                                           ↓
                              POST /api/analyze
                              (Auth check → Free tier → OpenAI → Save)
                                           ↓
                              Show 2 clauses (free) or all (pro)
                                           ↓
                              Paywall triggers after 4s
                                           ↓
                              POST /api/stripe/checkout → Stripe
                                           ↓
                              Stripe Webhook → Update subscription
```

## 💰 Revenue Model
- **Free tier:** 1 analysis, 2 clauses shown (hook)
- **Pro:** $9.99/month → unlimited analyses + full reports
- **7-day free trial** to reduce conversion friction

## 🚢 Deploy to Vercel
```bash
npm install -g vercel
vercel --prod
# Add env vars in Vercel dashboard
# Update Stripe webhook URL to production
```

---

## 📁 File Structure
```
contractscan/
├── app/
│   ├── page.tsx                    # Landing page (high-converting)
│   ├── dashboard/page.tsx          # Main app
│   ├── (auth)/login/page.tsx       # Auth
│   ├── (auth)/signup/page.tsx      # Auth
│   └── api/
│       ├── analyze/route.ts        # 🧠 Core AI analysis
│       └── stripe/
│           ├── checkout/route.ts   # 💳 Create checkout session
│           └── webhook/route.ts    # 🔔 Sync subscription status
├── components/dashboard/
│   ├── ContractUploader.tsx        # Drag & drop uploader
│   ├── AnalysisResult.tsx          # Risk display + paywall blur
│   └── PaywallModal.tsx            # 💰 The money moment
├── lib/
│   ├── openai.ts                   # GPT-4o analysis engine
│   ├── stripe.ts                   # Stripe config + helpers
│   └── supabase.ts                 # DB client + schema
├── types/index.ts                  # TypeScript types
└── middleware.ts                   # Route protection
```
