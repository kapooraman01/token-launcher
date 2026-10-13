import { Module } from '@nestjs/common';
import { ChainModule } from '../chain/chain.module';
import { IndexerService } from './indexer.service';
import { IndexerStore } from './indexer.store';
import { LogFetcher } from './log-fetcher.service';

@Module({
  imports: [ChainModule],
  providers: [LogFetcher, IndexerStore, IndexerService],
  exports: [IndexerService],
})
export class IndexerModule {}
