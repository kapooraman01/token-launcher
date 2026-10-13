import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { ApiModule } from './api.module';
import { ChainModule } from './chain/chain.module';
import { validateEnv } from './config/env.schema';
import { IndexerModule } from './indexer/indexer.module';
import { PrismaModule } from './prisma/prisma.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true, validate: validateEnv }),
    PrismaModule,
    ChainModule,
    IndexerModule,
    ApiModule,
  ],
})
export class AppModule {}
