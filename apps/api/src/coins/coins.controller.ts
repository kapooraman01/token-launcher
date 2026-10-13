import { Controller, Get, Param, Query } from '@nestjs/common';
import { ParseAddressPipe } from '../common/parse-address.pipe';
import { Page } from '../common/pagination';
import { CoinResponse, TradeResponse } from './coin.presenter';
import { CoinsService } from './coins.service';
import { ListCoinsQuery } from './dto/list-coins.query';
import { ListTradesQuery } from './dto/list-trades.query';

@Controller('coins')
export class CoinsController {
  constructor(private readonly coins: CoinsService) {}

  @Get()
  list(@Query() query: ListCoinsQuery): Promise<Page<CoinResponse>> {
    return this.coins.list(query.limit, query.cursor);
  }

  @Get(':address')
  get(
    @Param('address', ParseAddressPipe) address: string,
  ): Promise<CoinResponse> {
    return this.coins.get(address);
  }

  @Get(':address/trades')
  trades(
    @Param('address', ParseAddressPipe) address: string,
    @Query() query: ListTradesQuery,
  ): Promise<Page<TradeResponse>> {
    return this.coins.trades(address, query.limit, query.cursor);
  }
}
