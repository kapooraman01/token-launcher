-- AlterTable
ALTER TABLE "Coin" ADD COLUMN     "graduated" BOOLEAN NOT NULL DEFAULT false,
ADD COLUMN     "graduatedBlock" BIGINT,
ADD COLUMN     "poolEth" DECIMAL(78,0),
ADD COLUMN     "poolId" TEXT,
ADD COLUMN     "poolTokens" DECIMAL(78,0);
