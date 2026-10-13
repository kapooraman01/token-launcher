-- CreateEnum
CREATE TYPE "TradeSide" AS ENUM ('BUY', 'SELL');

-- CreateTable
CREATE TABLE "Coin" (
    "address" TEXT NOT NULL,
    "curveAddress" TEXT NOT NULL,
    "creator" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "symbol" TEXT NOT NULL,
    "targetRaise" DECIMAL(78,0) NOT NULL,
    "initialVirtualEth" DECIMAL(78,0) NOT NULL,
    "platformFeeBps" INTEGER NOT NULL,
    "creatorFeeBps" INTEGER NOT NULL,
    "antiSnipeFeeBps" INTEGER NOT NULL,
    "antiSnipeDuration" INTEGER NOT NULL,
    "virtualEthReserve" DECIMAL(78,0) NOT NULL,
    "virtualTokenReserve" DECIMAL(78,0) NOT NULL,
    "completed" BOOLEAN NOT NULL DEFAULT false,
    "completedBlock" BIGINT,
    "createdBlock" BIGINT NOT NULL,
    "createdTxHash" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Coin_pkey" PRIMARY KEY ("address")
);

-- CreateTable
CREATE TABLE "Trade" (
    "id" BIGSERIAL NOT NULL,
    "coinAddress" TEXT NOT NULL,
    "side" "TradeSide" NOT NULL,
    "trader" TEXT NOT NULL,
    "ethAmount" DECIMAL(78,0) NOT NULL,
    "tokenAmount" DECIMAL(78,0) NOT NULL,
    "platformFee" DECIMAL(78,0) NOT NULL,
    "creatorFee" DECIMAL(78,0) NOT NULL,
    "virtualEthReserve" DECIMAL(78,0) NOT NULL,
    "virtualTokenReserve" DECIMAL(78,0) NOT NULL,
    "blockNumber" BIGINT NOT NULL,
    "blockHash" TEXT NOT NULL,
    "txHash" TEXT NOT NULL,
    "logIndex" INTEGER NOT NULL,
    "timestamp" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Trade_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "IndexerState" (
    "id" TEXT NOT NULL,
    "lastBlock" BIGINT NOT NULL,
    "lastBlockHash" TEXT NOT NULL,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "IndexerState_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "IndexerCheckpoint" (
    "indexerId" TEXT NOT NULL,
    "blockNumber" BIGINT NOT NULL,
    "blockHash" TEXT NOT NULL,

    CONSTRAINT "IndexerCheckpoint_pkey" PRIMARY KEY ("indexerId","blockNumber")
);

-- CreateIndex
CREATE UNIQUE INDEX "Coin_curveAddress_key" ON "Coin"("curveAddress");

-- CreateIndex
CREATE INDEX "Coin_createdBlock_idx" ON "Coin"("createdBlock");

-- CreateIndex
CREATE INDEX "Coin_creator_idx" ON "Coin"("creator");

-- CreateIndex
CREATE INDEX "Trade_coinAddress_blockNumber_logIndex_idx" ON "Trade"("coinAddress", "blockNumber", "logIndex");

-- CreateIndex
CREATE INDEX "Trade_blockNumber_idx" ON "Trade"("blockNumber");

-- CreateIndex
CREATE UNIQUE INDEX "Trade_txHash_logIndex_key" ON "Trade"("txHash", "logIndex");

-- AddForeignKey
ALTER TABLE "Trade" ADD CONSTRAINT "Trade_coinAddress_fkey" FOREIGN KEY ("coinAddress") REFERENCES "Coin"("address") ON DELETE CASCADE ON UPDATE CASCADE;
