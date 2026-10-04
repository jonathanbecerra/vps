FROM node:24-alpine AS base

RUN corepack enable && corepack install --global pnpm@12.8.1

WORKDIR /app

FROM base AS build

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY tsconfig.json ./
COPY src ./src
RUN pnpm run build && pnpm prune --prod

FROM base

ENV NODE_ENV=production
COPY --from=build /app/package.json /app/package.json
COPY --from=build /app/node_modules /app/node_modules
COPY --from=build /app/dist /app/dist
USER node
EXPOSE 3000
CMD ["node", "dist/index.js"]
