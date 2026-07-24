FROM node:18-slim
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --production
COPY . .
EXPOSE 3000
CMD ["node", "src/server.js"]
